-- | Entry point for the code-generating executable `protoc` plugin. See the
-- | package README for instructions on how to run the code generator.
-- |
-- | The funny thing about writing a `protoc` compiler plugin codec is that it
-- | bootstraps itself. We just have to write enough of the compiler plugin codec
-- | that it can handle the `plugin.proto` and `descriptor.proto` files, and
-- | then we call the compiler plugin on these `.proto` files and the compiler
-- | plugin codec generates the rest of itself.
-- |
-- | Then we can delete the hand-written code and generate code to replace it
-- | with this command.
-- |
-- |     protoc --purescript_out=./src/ProtocPlugin google/protobuf/compiler/plugin.proto
-- |
-- | See
-- | * https://developers.google.com/protocol-buffers/docs/reference/cpp/google.protobuf.compiler.plugin.pb
-- | * https://developers.google.com/protocol-buffers/docs/reference/cpp/google.protobuf.descriptor.pb
module ProtocPlugin.Main (main) where

import Prelude
import Data.Array (catMaybes, concatMap, fold)
import Data.Array as Array
import Data.ArrayBuffer.Builder (execPut)
import Data.ArrayBuffer.DataView as DV
import Data.Either (Either(..))
import Data.Long.Internal (fromLowHighBits)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.String as String
import Data.String.Pattern as String.Pattern
import Data.String.Regex as String.Regex
import Data.String.Regex.Flags as String.Regex.Flags
import Data.Traversable (sequence, traverse)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Google.Protobuf.Compiler.Plugin (CodeGeneratorRequest(..), CodeGeneratorResponse, CodeGeneratorResponse_File(..), mkCodeGeneratorResponse, parseCodeGeneratorRequest, putCodeGeneratorResponse)
import Google.Protobuf.Descriptor (DescriptorProto(..), EnumDescriptorProto(..), EnumValueDescriptorProto(..), FieldDescriptorProto(..), FieldDescriptorProto_Label(..), FieldDescriptorProto_Type(..), FieldOptions(..), FileDescriptorProto(..), OneofDescriptorProto(..))
import Node.Buffer (toArrayBuffer, fromArrayBuffer)
import Node.Encoding (Encoding(..))
import Node.Path (basenameWithoutExt)
import Node.Process (stdin, stdout, stderr)
import Node.Stream (read, write, writeString, onReadable)
import Text.Parsing.Parser (runParserT)

main :: Effect Unit
main = do
  onReadable stdin
    $ do
        stdinbufMay <- read stdin Nothing
        case stdinbufMay of
          Nothing -> pure unit
          Just stdinbuf -> do
            stdinab <- toArrayBuffer stdinbuf
            let
              stdinview = DV.whole stdinab
            requestParsed <- runParserT stdinview $ parseCodeGeneratorRequest $ DV.byteLength stdinview
            case requestParsed of
              Left err -> void $ writeString stderr UTF8 (show err) (pure unit)
              Right request -> do
                -- Uncomment this line to write the parsed declarations to stderr.
                -- void $ writeString stderr UTF8 (show request) (pure unit)
                let
                  response = generate request
                responseab <- execPut $ putCodeGeneratorResponse response
                responsebuffer <- fromArrayBuffer responseab
                void $ write stdout responsebuffer (pure unit)

generate :: CodeGeneratorRequest -> CodeGeneratorResponse
generate (CodeGeneratorRequest { file_to_generate, parameter, proto_file, compiler_version }) = do
  case traverse (genFile proto_file) proto_file of
    Right file ->
      mkCodeGeneratorResponse
        { error: Nothing
        , file: file
        , supported_features: Just $ fromLowHighBits feature_proto3_optional 0
        }
    Left err ->
      mkCodeGeneratorResponse
        { error: Just err
        , supported_features: Just $ fromLowHighBits feature_proto3_optional 0
        }
  where
  -- https://github.com/protocolbuffers/protobuf/blob/3f5fc4df1de8e12b2235c3006593e22d6993c3f5/src/google/protobuf/compiler/plugin.proto#L115
  feature_none = 0

  feature_proto3_optional = 1

-- | Names of parent messages for a message or enum.
type NameSpace
  = Array String

-- | A message descriptor, plus the names of all parent messages.
data ScopedMsg
  = ScopedMsg NameSpace DescriptorProto

-- | An enum descriptor, plus the names of all parent messages.
data ScopedEnum
  = ScopedEnum NameSpace EnumDescriptorProto

-- | Scoped field name which has the qualified package namespace and the field name.
data ScopedField
  = ScopedField NameSpace String

-- | This is how we'll return errors while trying to generate the response from the request.
type Resp a
  = Either String a

genFile :: Array FileDescriptorProto -> FileDescriptorProto -> Resp CodeGeneratorResponse_File
genFile proto_file ( FileDescriptorProto
    { name: fileName
  , package
  , dependency
  , public_dependency
  , message_type
  , enum_type
  , syntax
  }
) = do
  let
    baseName = case fileName of
      Nothing -> "Generated"
      Just "" -> "Generated"
      Just n -> basenameWithoutExt n ".proto"
  messages :: Array ScopedMsg <- sequence $ flattenMessages [] message_type
  enums :: Array ScopedEnum <- Right (ScopedEnum [] <$> enum_type) <> sequence (flattenEnums [] message_type)
  let
    packageName = case package of -- Optional package, https://developers.google.com/protocol-buffers/docs/proto3#packages
      Nothing -> []
      Just ps -> String.split (String.Pattern.Pattern ".") ps
  let
    fileNameOut = baseName <> "." <> (String.joinWith "." ((map capitalize packageName))) <> ".purs"
  -- We have to import the modules qualified in the way because
  -- 1. When protoc "fully qualifies" a field type from an imported
  --    desriptor, the qualification consists of only the package name
  -- 2. protoc allows multiple files to have the same package name,
  --    such as descriptor.proto and any.proto (package "google.protobuf")
  --    but Purescript requires each file to have a different module name.
  let
    genImport :: String -> Resp String
    genImport fpath = do
      pkg <- lookupPackageByFilepath
      let
        moduleName = mkImportName fpath pkg
      let
        qualifiedName = Array.dropEnd 1 moduleName
      Right $ "import " <> make moduleName <> " as " <> make qualifiedName
      where
      make = String.joinWith "." <<< map capitalize

      lookupPackageByFilepath :: Resp (Array String)
      lookupPackageByFilepath = case Array.find (\(FileDescriptorProto f) -> maybe false (_ == fpath) f.name) proto_file of
        Just (FileDescriptorProto { package: Just p }) -> Right $ String.split (String.Pattern.Pattern ".") p
        _ -> Left $ "Failed genImport lookupPackageByFilepath " <> fpath

      mkImportName ::
        -- file path
        String ->
        -- package name
        Array String ->
        Array String
      mkImportName fileString packages = map mkModuleName $ packages <> file
        where
        file = [ basenameWithoutExt fileString ".proto" ]
  let
    mkFieldType ::
      -- prefix for the name, i.e. "put" "parse"
      String ->
      -- package-qualified period-separated field name
      String ->
      String
    mkFieldType prefix s =
      let
        (ScopedField names name) = parseFieldName s
      in
        if names `beginsWith` packageName && (isLocalMessageName name || isLocalEnumName name) then
          -- it's a name in this package
          prefix <> (mkTypeName $ Array.drop (Array.length packageName) names <> [ name ])
        else
          -- it's a name in the top-level of an imported package
          String.joinWith "." $ (map mkModuleName $ names) <> [ prefix <> capitalize name ]
      where
      isLocalMessageName :: String -> Boolean
      isLocalMessageName fname =
        maybe false (const true)
          $ flip Array.find messages
          $ \(ScopedMsg _ (DescriptorProto { name })) ->
              maybe false (fname == _) name

      isLocalEnumName :: String -> Boolean
      isLocalEnumName ename =
        maybe false (const true)
          $ flip Array.find enums
          $ \(ScopedEnum _ (EnumDescriptorProto { name })) ->
              maybe false (ename == _) name

      parseFieldName :: String -> ScopedField
      parseFieldName fname =
        if String.take 1 fname == "." then
          -- fully qualified
          let
            names = Array.dropWhile (_ == "") $ String.split (String.Pattern.Pattern ".") fname
          in
            ScopedField (Array.dropEnd 1 names) (fromMaybe "" $ Array.last names)
        else
          ScopedField [] fname -- this case should never occur, protoc always qualifies the names for us

      beginsWith :: Array String -> Array String -> Boolean
      beginsWith xs x = x == Array.take (Array.length x) xs
  -- We have an r and we're merging an l.
  -- About merging: https://github.com/protocolbuffers/protobuf/blob/master/docs/field_presence.md
  let
    genFieldMerge :: FieldDescriptorProto -> Resp String
    genFieldMerge ( FieldDescriptorProto
        { name: Just name'
      , label: Just FieldDescriptorProto_Label_LABEL_REPEATED
      }
    ) = Right $ fname <> ": r." <> fname <> " <> l." <> fname
      where
      fname = decapitalize name'

    genFieldMerge ( FieldDescriptorProto
        { name: Just name'
      , label: Just _
      , type: Just FieldDescriptorProto_Type_TYPE_MESSAGE
      , type_name: Just tname
      }
    ) = Right $ fname <> ": Prelude.mergeWith " <> mkFieldType "merge" tname <> " l." <> fname <> " r." <> fname
      where
      fname = decapitalize name'

    genFieldMerge ( FieldDescriptorProto
        { name: Just name'
      , label: Just _
      , type: Just _
      }
    ) = Right $ fname <> ": Prelude.alt l." <> fname <> " r." <> fname
      where
      fname = decapitalize name'

    genFieldMerge _ = Left "Failed genFieldDefault missing FieldDescriptorProto name or label"
  let
    genFieldMergeOneof ::
      NameSpace ->
      (Tuple OneofDescriptorProto (Array FieldDescriptorProto)) ->
      Resp String
    genFieldMergeOneof nameSpace (Tuple (OneofDescriptorProto { name: Just oname }) _) = Right $ fname <> ": merge" <> cname <> " l." <> fname <> " r." <> fname
      where
      fname = decapitalize oname

      cname = String.joinWith "_" $ map capitalize $ nameSpace <> [ oname ]

    genFieldMergeOneof _ _ = Left "Failed genFieldMergeOneof missing name"
  let
    genOneofMerge ::
      NameSpace ->
      (Tuple OneofDescriptorProto (Array FieldDescriptorProto)) ->
      Resp String
    genOneofMerge nameSpace (Tuple (OneofDescriptorProto { name: Just oname }) fields) = do
      Right $ "merge" <> cname <> " :: Prelude.Maybe " <> cname <> " -> Prelude.Maybe " <> cname <> " -> Prelude.Maybe " <> cname <> "\n"
        <> "merge"
        <> cname
        <> " l r = case Prelude.Tuple l r of\n"
        <> (fold $ catMaybes $ map genField fields)
        <> "  _ -> Prelude.alt l r\n"
      where
      cname = String.joinWith "_" $ map capitalize $ nameSpace <> [ oname ]

      genField :: FieldDescriptorProto -> Maybe String
      genField ( FieldDescriptorProto
          { type: Just FieldDescriptorProto_Type_TYPE_MESSAGE
        , name: Just name_inner
        , type_name: Just tname
        }
      ) = Just $ "  Prelude.Tuple (Prelude.Just (" <> fname_inner <> " l')) (Prelude.Just (" <> fname_inner <> " r')) -> Prelude.map " <> fname_inner <> " $ Prelude.mergeWith " <> mkFieldType "merge" tname <> " (Prelude.Just l') (Prelude.Just r')\n"
        where
        fname_inner = String.joinWith "_" $ map capitalize [ cname, name_inner ]

      genField _ = Nothing

    genOneofMerge _ _ = Left "Failed genOneofMerge missing name"
  let
    genTypeOneof ::
      NameSpace ->
      (Tuple OneofDescriptorProto (Array FieldDescriptorProto)) ->
      Resp String
    genTypeOneof nameSpace (Tuple (OneofDescriptorProto { name: Just oname }) pfields) = do
      fields <- catMaybes <$> traverse go pfields
      Right
        $ String.joinWith "\n"
            [ "data " <> cname
            , "  = " <> String.joinWith "\n  | " fields
            , ""
            , "derive instance generic" <> cname <> " :: Prelude.Generic " <> cname <> " _"
            , "derive instance eq" <> cname <> " :: Prelude.Eq " <> cname
            , "instance show" <> cname <> " :: Prelude.Show " <> cname <> " where show = Prelude.genericShow"
            , ""
            ]
      where
      cname = String.joinWith "_" $ map capitalize $ nameSpace <> [ oname ]

      go :: FieldDescriptorProto -> Resp (Maybe String)
      go (FieldDescriptorProto { name: Just fname, oneof_index: Just index, type: Just ftype, type_name }) = do
        fieldType <- genFieldType ftype type_name
        Right $ Just $ (String.joinWith "_" $ map capitalize [ cname, fname ]) <> " " <> fieldType
        where
        genFieldType :: FieldDescriptorProto_Type -> Maybe String -> Resp String
        genFieldType FieldDescriptorProto_Type_TYPE_DOUBLE _ = Right "Number"

        genFieldType FieldDescriptorProto_Type_TYPE_FLOAT _ = Right "Prelude.Float32"

        genFieldType FieldDescriptorProto_Type_TYPE_INT64 _ = Right "(Prelude.Long Prelude.Signed)"

        genFieldType FieldDescriptorProto_Type_TYPE_UINT64 _ = Right "(Prelude.Long Prelude.Unsigned)"

        genFieldType FieldDescriptorProto_Type_TYPE_INT32 _ = Right "Int"

        genFieldType FieldDescriptorProto_Type_TYPE_FIXED64 _ = Right "(Prelude.Long Prelude.Unsigned)"

        genFieldType FieldDescriptorProto_Type_TYPE_FIXED32 _ = Right "Prelude.UInt"

        genFieldType FieldDescriptorProto_Type_TYPE_BOOL _ = Right "Boolean"

        genFieldType FieldDescriptorProto_Type_TYPE_STRING _ = Right "String"

        genFieldType FieldDescriptorProto_Type_TYPE_MESSAGE (Just tname) = Right $ mkFieldType "" tname

        genFieldType FieldDescriptorProto_Type_TYPE_MESSAGE _ = Left "Failed genTypeOneof missing FieldDescriptorProto type_name"

        genFieldType FieldDescriptorProto_Type_TYPE_BYTES _ = Right "Prelude.Bytes"

        genFieldType FieldDescriptorProto_Type_TYPE_UINT32 _ = Right "Prelude.UInt"

        genFieldType FieldDescriptorProto_Type_TYPE_ENUM (Just tname) = Right $ mkFieldType "" tname

        genFieldType FieldDescriptorProto_Type_TYPE_ENUM _ = Left "Failed genTypeOneof missing FieldDescriptorProto type_name"

        genFieldType FieldDescriptorProto_Type_TYPE_SFIXED32 _ = Right "Int"

        genFieldType FieldDescriptorProto_Type_TYPE_SFIXED64 _ = Right "(Prelude.Long Prelude.Signed)"

        genFieldType FieldDescriptorProto_Type_TYPE_SINT32 _ = Right "Int"

        genFieldType FieldDescriptorProto_Type_TYPE_SINT64 _ = Right "(Prelude.Long Prelude.Signed)"

        genFieldType FieldDescriptorProto_Type_TYPE_GROUP _ = Left "Failed genTypeOneof GROUP not supported."

      go _ = Right Nothing

    genTypeOneof _ _ = Left $ "Failed genTypeOneof missing OneofDescriptorProto name\n"
  let
    genIsDefaultOneof ::
      NameSpace ->
      (Tuple OneofDescriptorProto (Array FieldDescriptorProto)) ->
      Resp String
    genIsDefaultOneof nameSpace (Tuple (OneofDescriptorProto { name: Just oname }) pfields) = do
      fields <- catMaybes <$> traverse go pfields
      Right
        $ String.joinWith "\n"
            [ "isDefault" <> cname <> " :: " <> cname <> " -> Boolean"
            , String.joinWith "\n" fields
            , ""
            ]
      where
      cname = String.joinWith "_" $ map capitalize $ nameSpace <> [ oname ]

      go :: FieldDescriptorProto -> Resp (Maybe String)
      go (FieldDescriptorProto { name: Just fname, type: Just FieldDescriptorProto_Type_TYPE_MESSAGE, type_name }) = Right $ Just $ "isDefault" <> cname <> " (" <> (String.joinWith "_" $ map capitalize [ cname, fname ]) <> " _) = false"

      go (FieldDescriptorProto { name: Just fname, type: _, type_name }) = Right $ Just $ "isDefault" <> cname <> " (" <> (String.joinWith "_" $ map capitalize [ cname, fname ]) <> " x) = Prelude.isDefault x"

      go _ = Right Nothing

    genIsDefaultOneof _ _ = Left $ "Failed genIsDefaultOneof missing OneofDescriptorProto name\n"
  let
    genOneofPut :: NameSpace -> (Tuple OneofDescriptorProto (Array FieldDescriptorProto)) -> Resp String
    genOneofPut nameSpace (Tuple (OneofDescriptorProto { name: Just oname }) myfields) =
      map (String.joinWith "\n") $ sequence
        $ [ Right $ "  case r." <> decapitalize oname <> " of"
          , Right "    Prelude.Nothing -> pure Prelude.unit"
          ]
        <> (map genOneofFieldPut myfields)
      where
      genOneofFieldPut :: FieldDescriptorProto -> Resp String
      genOneofFieldPut ( FieldDescriptorProto
          { name: Just name'
        , number: Just fnumber
        , type: Just ftype
        , type_name
        }
      ) = go ftype type_name
        where
        fname = decapitalize name'

        -- If you set a oneof field to the default value (such as setting an int32 oneof field to 0), the "case" of that oneof field will be set, and the value will be serialized on the wire.
        -- https://developers.google.com/protocol-buffers/docs/proto3#oneof_features
        go FieldDescriptorProto_Type_TYPE_DOUBLE _ = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) Prelude.encodedouble"

        go FieldDescriptorProto_Type_TYPE_FLOAT _ = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) Prelude.encodefloat"

        go FieldDescriptorProto_Type_TYPE_INT64 _ = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) Prelude.encodeint64"

        go FieldDescriptorProto_Type_TYPE_UINT64 _ = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) Prelude.encodeuint64"

        go FieldDescriptorProto_Type_TYPE_INT32 _ = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) Prelude.encodeint32"

        go FieldDescriptorProto_Type_TYPE_FIXED64 _ = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) Prelude.encodefixed64"

        go FieldDescriptorProto_Type_TYPE_FIXED32 _ = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) Prelude.encodefixed32"

        go FieldDescriptorProto_Type_TYPE_BOOL _ = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) Prelude.encodebool"

        go FieldDescriptorProto_Type_TYPE_STRING _ = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) Prelude.encodestring"

        go FieldDescriptorProto_Type_TYPE_MESSAGE (Just tname) = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) $ Prelude.putLenDel " <> mkFieldType "put" tname

        go FieldDescriptorProto_Type_TYPE_MESSAGE _ = Left "Failed genOneofPut missing FieldDescriptorProto type_name"

        go FieldDescriptorProto_Type_TYPE_BYTES _ = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) Prelude.encodebytes"

        go FieldDescriptorProto_Type_TYPE_UINT32 _ = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) Prelude.encodeuint32"

        go FieldDescriptorProto_Type_TYPE_ENUM _ = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) Prelude.putEnum"

        go FieldDescriptorProto_Type_TYPE_SFIXED32 _ = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) Prelude.encodesfixed32"

        go FieldDescriptorProto_Type_TYPE_SFIXED64 _ = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) Prelude.encodesfixed64"

        go FieldDescriptorProto_Type_TYPE_SINT32 _ = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) Prelude.encodesint32"

        go FieldDescriptorProto_Type_TYPE_SINT64 _ = Right $ "    Prelude.Just (" <> mkTypeName (nameSpace <> [ oname, name' ]) <> " x) -> Prelude.putOptional " <> show fnumber <> " (Prelude.Just x) (\\_ -> false) Prelude.encodesint64"

        go FieldDescriptorProto_Type_TYPE_GROUP _ = Left "Failed genOneofPut GROUP not supported."

      genOneofFieldPut _ = Left "Failed genOneofPut missing FieldDescriptorProto name or number or type"

    genOneofPut _ _ = Left "Failed genOneofPut missing OneofDescriptoroProto name"
  let
    genFieldPut :: NameSpace -> FieldDescriptorProto -> Resp String
    genFieldPut nameSpace ( FieldDescriptorProto
        { name: Just name'
      , number: Just fnumber
      , label: Just flabel
      , type: Just ftype
      , type_name
      , options
      , proto3_optional
      }
    ) = go flabel ftype type_name options
      where
      isSyntheticOneof = fromMaybe false proto3_optional

      fname = decapitalize name'

      -- For repeated fields of primitive numeric types, always put the packed
      -- encoding.
      -- https://developers.google.com/protocol-buffers/docs/encoding?hl=en#packed
      -- For optional synthetic Oneofs, write even if it's the default value.
      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_DOUBLE _ (Just (FieldOptions { packed: Just false })) = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " Prelude.encodedouble"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_DOUBLE _ _ = Right $ "  Prelude.putPacked " <> show fnumber <> " r." <> fname <> " Prelude.encodedouble'"

      go _ FieldDescriptorProto_Type_TYPE_DOUBLE _ _ =
        if isSyntheticOneof then
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) Prelude.encodedouble"
        else
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " Prelude.isDefault Prelude.encodedouble"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_FLOAT _ (Just (FieldOptions { packed: Just false })) = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " Prelude.encodefloat"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_FLOAT _ _ = Right $ "  Prelude.putPacked " <> show fnumber <> " r." <> fname <> " Prelude.encodefloat'"

      go _ FieldDescriptorProto_Type_TYPE_FLOAT _ _ =
        if isSyntheticOneof then
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) Prelude.encodefloat"
        else
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " Prelude.isDefault Prelude.encodefloat"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_INT64 _ (Just (FieldOptions { packed: Just false })) = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " Prelude.encodeint64"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_INT64 _ _ = Right $ "  Prelude.putPacked " <> show fnumber <> " r." <> fname <> " Prelude.encodeint64'"

      go _ FieldDescriptorProto_Type_TYPE_INT64 _ _ =
        if isSyntheticOneof then
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) Prelude.encodeint64"
        else
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " Prelude.isDefault Prelude.encodeint64"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_UINT64 _ (Just (FieldOptions { packed: Just false })) = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " Prelude.encodeuint64"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_UINT64 _ _ = Right $ "  Prelude.putPacked " <> show fnumber <> " r." <> fname <> " Prelude.encodeuint64'"

      go _ FieldDescriptorProto_Type_TYPE_UINT64 _ _ =
        if isSyntheticOneof then
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) Prelude.encodeuint64"
        else
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " Prelude.isDefault Prelude.encodeuint64"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_INT32 _ (Just (FieldOptions { packed: Just false })) = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " Prelude.encodeint32"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_INT32 _ _ = Right $ "  Prelude.putPacked " <> show fnumber <> " r." <> fname <> " Prelude.encodeint32'"

      go _ FieldDescriptorProto_Type_TYPE_INT32 _ _ =
        if isSyntheticOneof then
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) Prelude.encodeint32"
        else
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " Prelude.isDefault Prelude.encodeint32"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_FIXED64 _ (Just (FieldOptions { packed: Just false })) = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " Prelude.encodefixed64"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_FIXED64 _ _ = Right $ "  Prelude.putPacked " <> show fnumber <> " r." <> fname <> " Prelude.encodefixed64'"

      go _ FieldDescriptorProto_Type_TYPE_FIXED64 _ _ =
        if isSyntheticOneof then
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) Prelude.encodefixed64"
        else
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " Prelude.isDefault Prelude.encodefixed64"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_FIXED32 _ (Just (FieldOptions { packed: Just false })) = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " Prelude.encodefixed32"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_FIXED32 _ _ = Right $ "  Prelude.putPacked " <> show fnumber <> " r." <> fname <> " Prelude.encodefixed32'"

      go _ FieldDescriptorProto_Type_TYPE_FIXED32 _ _ =
        if isSyntheticOneof then
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) Prelude.encodefixed32"
        else
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " Prelude.isDefault Prelude.encodefixed32"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_BOOL _ (Just (FieldOptions { packed: Just false })) = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " Prelude.encodebool"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_BOOL _ _ = Right $ "  Prelude.putPacked " <> show fnumber <> " r." <> fname <> " Prelude.encodebool'"

      go _ FieldDescriptorProto_Type_TYPE_BOOL _ _ =
        if isSyntheticOneof then
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) Prelude.encodebool"
        else
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " Prelude.isDefault Prelude.encodebool"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_STRING _ _ = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " Prelude.encodestring"

      go _ FieldDescriptorProto_Type_TYPE_STRING _ _ =
        if isSyntheticOneof then
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) Prelude.encodestring"
        else
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " Prelude.isDefault Prelude.encodestring"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_MESSAGE (Just tname) _ = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " $ Prelude.putLenDel " <> mkFieldType "put" tname

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_MESSAGE _ _ = Left "Failed genFieldPut missing FieldDescriptorProto type_name"

      go _ FieldDescriptorProto_Type_TYPE_MESSAGE (Just tname) _ = Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) $ Prelude.putLenDel " <> mkFieldType "put" tname

      go _ FieldDescriptorProto_Type_TYPE_MESSAGE _ _ = Left "Failed genFieldPut missing FieldDescriptorProto type_name"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_BYTES _ _ = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " $ Prelude.encodebytes"

      go _ FieldDescriptorProto_Type_TYPE_BYTES _ _ =
        if isSyntheticOneof then
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) Prelude.encodebytes"
        else
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " Prelude.isDefault Prelude.encodebytes"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_UINT32 _ (Just (FieldOptions { packed: Just false })) = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " Prelude.encodeuint32"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_UINT32 _ _ = Right $ "  Prelude.putPacked " <> show fnumber <> " r." <> fname <> " Prelude.encodeuint32'"

      go _ FieldDescriptorProto_Type_TYPE_UINT32 _ _ =
        if isSyntheticOneof then
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) Prelude.encodeuint32"
        else
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " Prelude.isDefault Prelude.encodeuint32"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_ENUM _ (Just (FieldOptions { packed: Just false })) = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " Prelude.putEnum"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_ENUM _ _ = Right $ "  Prelude.putPacked " <> show fnumber <> " r." <> fname <> " Prelude.putEnum'"

      go _ FieldDescriptorProto_Type_TYPE_ENUM _ _ =
        if isSyntheticOneof then
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) Prelude.putEnum"
        else
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " Prelude.isDefault Prelude.putEnum"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_SFIXED32 _ (Just (FieldOptions { packed: Just false })) = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " Prelude.encodesfixed32"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_SFIXED32 _ _ = Right $ "  Prelude.putPacked " <> show fnumber <> " r." <> fname <> " Prelude.encodesfixed32'"

      go _ FieldDescriptorProto_Type_TYPE_SFIXED32 _ _ =
        if isSyntheticOneof then
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) Prelude.encodesfixed32"
        else
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " Prelude.isDefault Prelude.encodesfixed32"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_SFIXED64 _ (Just (FieldOptions { packed: Just false })) = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " Prelude.encodesfixed64"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_SFIXED64 _ _ = Right $ "  Prelude.putPacked " <> show fnumber <> " r." <> fname <> " Prelude.encodesfixed64'"

      go _ FieldDescriptorProto_Type_TYPE_SFIXED64 _ _ =
        if isSyntheticOneof then
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) Prelude.encodesfixed64"
        else
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " Prelude.isDefault Prelude.encodesfixed64"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_SINT32 _ (Just (FieldOptions { packed: Just false })) = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " Prelude.encodesint32"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_SINT32 _ _ = Right $ "  Prelude.putPacked " <> show fnumber <> " r." <> fname <> " Prelude.encodesint32'"

      go _ FieldDescriptorProto_Type_TYPE_SINT32 _ _ =
        if isSyntheticOneof then
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) Prelude.encodesint32"
        else
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " Prelude.isDefault Prelude.encodesint32"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_SINT64 _ (Just (FieldOptions { packed: Just false })) = Right $ "  Prelude.putRepeated " <> show fnumber <> " r." <> fname <> " Prelude.encodesint64"

      go FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_SINT64 _ _ = Right $ "  Prelude.putPacked " <> show fnumber <> " r." <> fname <> " Prelude.encodesint64'"

      go _ FieldDescriptorProto_Type_TYPE_SINT64 _ _ =
        if isSyntheticOneof then
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " (\\_ -> false) Prelude.encodesint64"
        else
          Right $ "  Prelude.putOptional " <> show fnumber <> " r." <> fname <> " Prelude.isDefault Prelude.encodesint64"

      go _ FieldDescriptorProto_Type_TYPE_GROUP _ _ = Left "Failed genFieldPut GROUP not supported"

    genFieldPut _ arg = Left $ "Failed genFieldPut missing FieldDescriptorProto name or number or label or type\n" <> show arg
  let
    genFieldParser :: NameSpace -> Array OneofDescriptorProto -> FieldDescriptorProto -> Resp String
    genFieldParser nameSpace oneof_decl ( FieldDescriptorProto
        { name: Just name'
      , number: Just fnumber
      , label: Just flabel
      , type: Just ftype
      , type_name
      , oneof_index
      , proto3_optional
      }
    ) = go (lookupOneof oneof_index) flabel ftype type_name
      where
      lookupOneof :: Maybe Int -> Maybe String
      lookupOneof Nothing = Nothing

      lookupOneof (Just i) = case Array.index oneof_decl i of
        Just (OneofDescriptorProto { name }) -> case proto3_optional of
          Just true -> Nothing -- If it's an optional synthetic Oneof, then we pretend it's not a Oneof at all.
          _ -> name
        _ -> Nothing

      fname = decapitalize name'

      mkConstructor oname = mkTypeName (nameSpace <> [ oname, name' ])

      -- For repeated fields of primitive numeric types, also parse the packed
      -- encoding.
      -- https://developers.google.com/protocol-buffers/docs/encoding?hl=en#packed
      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_DOUBLE _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits64 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.double"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              , "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel $ Prelude.doubleArray"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.append x"
              ]

      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_FLOAT _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits32 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.float"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              , "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel $ Prelude.floatArray"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.append x"
              ]

      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_INT64 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.int64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              , "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel $ Prelude.manyLength Prelude.int64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.append x"
              ]

      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_UINT64 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.uint64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              , "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel $ Prelude.manyLength Prelude.uint64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.append x"
              ]

      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_INT32 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.int32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              , "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel $ Prelude.manyLength Prelude.int32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.append x"
              ]

      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_FIXED64 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits64 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.fixed64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              , "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel $ Prelude.fixed64Array"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.append x"
              ]

      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_FIXED32 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits32 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.fixed32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              , "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel $ Prelude.fixed32Array"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.append x"
              ]

      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_BOOL _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.bool"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              , "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel $ Prelude.manyLength Prelude.bool"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.append x"
              ]

      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_STRING _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.string"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              ]

      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_MESSAGE (Just tname) =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel " <> mkFieldType "parse" tname
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              ]

      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_BYTES _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.bytes"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              ]

      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_UINT32 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.uint32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              , "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel $ Prelude.manyLength Prelude.uint32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.append x"
              ]

      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_ENUM _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseEnum"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              , "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel $ Prelude.manyLength Prelude.parseEnum"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.append x"
              ]

      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_SFIXED32 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits32 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.sfixed32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              , "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel $ Prelude.sfixed32Array"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.append x"
              ]

      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_SFIXED64 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits64 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.sfixed64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              , "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel $ Prelude.sfixed64Array"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.append x"
              ]

      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_SINT32 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.sint32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              , "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel $ Prelude.manyLength Prelude.sint32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.append x"
              ]

      go _ FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_SINT64 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.sint64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.snoc x"
              , "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel $ Prelude.manyLength Prelude.sint64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.flip Prelude.append x"
              ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_DOUBLE _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits64 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.double"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ \\_ -> Prelude.Just (" <> mkConstructor oname <> " x)"
              ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_FLOAT _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits32 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.float"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ \\_ -> Prelude.Just (" <> mkConstructor oname <> " x)"
              ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_INT64 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.int64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ \\_ -> Prelude.Just (" <> mkConstructor oname <> " x)"
              ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_UINT64 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.uint64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ \\_ -> Prelude.Just (" <> mkConstructor oname <> " x)"
              ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_INT32 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.int32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ \\_ -> Prelude.Just (" <> mkConstructor oname <> " x)"
              ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_FIXED64 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits64 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.fixed64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ \\_ ->  Prelude.Just (" <> mkConstructor oname <> " x)"
              ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_FIXED32 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits32 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.fixed32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ \\_ -> Prelude.Just (" <> mkConstructor oname <> " x)"
              ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_BOOL _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.bool"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ \\_ -> Prelude.Just (" <> mkConstructor oname <> " x)"
              ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_STRING _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.string"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ \\_ -> Prelude.Just (" <> mkConstructor oname <> " x)"
              ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_MESSAGE (Just tname) =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel " <> mkFieldType "parse" tname
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ " <> mkFieldType "merge" cname <> " (Prelude.Just (" <> mkConstructor oname <> " x))"
              ]
        where
        cname = String.joinWith "_" $ map capitalize $ nameSpace <> [ oname ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_BYTES _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.bytes"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ \\_ -> Prelude.Just (" <> mkConstructor oname <> " x)"
              ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_UINT32 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.uint32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ \\_ -> Prelude.Just (" <> mkConstructor oname <> " x)"
              ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_ENUM _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseEnum"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ \\_ -> Prelude.Just (" <> mkConstructor oname <> " x)"
              ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_SFIXED32 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits32 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.sfixed32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ \\_ -> Prelude.Just (" <> mkConstructor oname <> " x)"
              ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_SFIXED64 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits64 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.sfixed64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ \\_ -> Prelude.Just (" <> mkConstructor oname <> " x)"
              ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_SINT32 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.sint32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ \\_ -> Prelude.Just (" <> mkConstructor oname <> " x)"
              ]

      go (Just oname) _ FieldDescriptorProto_Type_TYPE_SINT64 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.sint64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> decapitalize oname <> "\") $ \\_ -> Prelude.Just (" <> mkConstructor oname <> " x)"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_DOUBLE _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits64 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.double"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ \\_ -> Prelude.Just x"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_FLOAT _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits32 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.float"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ \\_ -> Prelude.Just x"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_INT64 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.int64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ \\_ -> Prelude.Just x"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_UINT64 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.uint64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ \\_ -> Prelude.Just x"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_INT32 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.int32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ \\_ -> Prelude.Just x"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_FIXED64 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits64 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.fixed64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ \\_ -> Prelude.Just x"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_FIXED32 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits32 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.fixed32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ \\_ -> Prelude.Just x"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_BOOL _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.bool"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ \\_ -> Prelude.Just x"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_STRING _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.string"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ \\_ -> Prelude.Just x"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_MESSAGE (Just tname) =
        Right
          $ String.joinWith "\n"
              -- “merge all input elements if it's a message type field”
              -- https://developers.google.com/protocol-buffers/docs/proto3#updating
              -- https://developers.google.com/protocol-buffers/docs/encoding#optional
              [ "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseLenDel " <> mkFieldType "parse" tname
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ Prelude.Just Prelude.<<< Prelude.maybe x (" <> mkFieldType "merge" tname <> " x)"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_MESSAGE _ = Left "Failed genFieldParser missing FieldDescriptorProto type_name"

      go _ _ FieldDescriptorProto_Type_TYPE_BYTES _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.LenDel = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.bytes"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ \\_ -> Prelude.Just x"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_UINT32 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.uint32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ \\_ -> Prelude.Just x"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_ENUM _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.parseEnum"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ \\_ -> Prelude.Just x"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_SFIXED32 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits32 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.sfixed32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ \\_ -> Prelude.Just x"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_SFIXED64 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.Bits64 = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.sfixed64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ \\_ -> Prelude.Just x"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_SINT32 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.sint32"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ \\_ -> Prelude.Just x"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_SINT64 _ =
        Right
          $ String.joinWith "\n"
              [ "  parseField " <> show fnumber <> " Prelude.VarInt = Prelude.label \"" <> name' <> " / \" $ do"
              , "    x <- Prelude.sint64"
              , "    pure $ Prelude.modify (Prelude.SProxy :: Prelude.SProxy \"" <> fname <> "\") $ \\_ -> Prelude.Just x"
              ]

      go _ _ FieldDescriptorProto_Type_TYPE_GROUP _ = Left "Failed genFieldParser GROUP not supported"

    genFieldParser _ _ _ = Left "Failed genFieldParser missing FieldDescriptorProto name or number or label or type"
  -- | For embedded message fields, the parser merges multiple instances of the same field,
  -- | https://developers.google.com/protocol-buffers/docs/encoding?hl=en#optional
  let
    genFieldRecord :: NameSpace -> FieldDescriptorProto -> Resp (Maybe String)
    genFieldRecord nameSpace ( FieldDescriptorProto
        { name: Just name'
      , number: Just fnumber
      , label: Just flabel
      , type: Just ftype
      , type_name
      , oneof_index
      , proto3_optional
      }
    ) = (map <<< map) (\x -> fname <> " :: " <> x) $ ptype flabel ftype type_name
      where
      fname = decapitalize name'

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_DOUBLE _ = Right $ Just "Array Number"

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_FLOAT _ = Right $ Just "Array Prelude.Float32"

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_INT64 _ = Right $ Just "Array (Prelude.Long Prelude.Signed)"

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_UINT64 _ = Right $ Just "Array (Prelude.Long Prelude.Unsigned)"

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_INT32 _ = Right $ Just "Array Int"

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_FIXED64 _ = Right $ Just "Array (Prelude.Long Prelude.Unsigned)"

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_FIXED32 _ = Right $ Just "Array Prelude.UInt"

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_BOOL _ = Right $ Just "Array Boolean"

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_STRING _ = Right $ Just "Array String"

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_MESSAGE (Just tname) = Right $ Just $ "Array " <> mkFieldType "" tname

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_MESSAGE _ = Left "Failed genFieldRecord missing FieldDescriptorProto type_name"

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_BYTES _ = Right $ Just "Array Prelude.Bytes"

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_UINT32 _ = Right $ Just "Array Prelude.UInt"

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_ENUM (Just tname) = Right $ Just $ "Array " <> mkFieldType "" tname

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_ENUM _ = Left "Failed genFieldRecord missing FieldDescriptorProto type_name"

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_SFIXED32 _ = Right $ Just "Array Int"

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_SFIXED64 _ = Right $ Just "Array (Prelude.Long Prelude.Signed)"

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_SINT32 _ = Right $ Just "Array Int"

      ptype FieldDescriptorProto_Label_LABEL_REPEATED FieldDescriptorProto_Type_TYPE_SINT64 _ = Right $ Just "Array (Prelude.Long Prelude.Signed)"

      ptype _ FieldDescriptorProto_Type_TYPE_DOUBLE _ = Right $ Just "Prelude.Maybe Number"

      ptype _ FieldDescriptorProto_Type_TYPE_FLOAT _ = Right $ Just "Prelude.Maybe Prelude.Float32"

      ptype _ FieldDescriptorProto_Type_TYPE_INT64 _ = Right $ Just "Prelude.Maybe (Prelude.Long Prelude.Signed)"

      ptype _ FieldDescriptorProto_Type_TYPE_UINT64 _ = Right $ Just "Prelude.Maybe (Prelude.Long Prelude.Unsigned)"

      ptype _ FieldDescriptorProto_Type_TYPE_INT32 _ = Right $ Just "Prelude.Maybe Int"

      ptype _ FieldDescriptorProto_Type_TYPE_FIXED64 _ = Right $ Just "Prelude.Maybe (Prelude.Long Prelude.Unsigned)"

      ptype _ FieldDescriptorProto_Type_TYPE_FIXED32 _ = Right $ Just "Prelude.Maybe Prelude.UInt"

      ptype _ FieldDescriptorProto_Type_TYPE_BOOL _ = Right $ Just "Prelude.Maybe Boolean"

      ptype _ FieldDescriptorProto_Type_TYPE_STRING _ = Right $ Just "Prelude.Maybe String"

      ptype _ FieldDescriptorProto_Type_TYPE_MESSAGE (Just tname) = Right $ Just $ "Prelude.Maybe " <> mkFieldType "" tname

      ptype _ FieldDescriptorProto_Type_TYPE_MESSAGE _ = Left "Failed genFieldRecord missing FieldDescriptorProto type_name"

      ptype _ FieldDescriptorProto_Type_TYPE_BYTES _ = Right $ Just "Prelude.Maybe Prelude.Bytes"

      ptype _ FieldDescriptorProto_Type_TYPE_UINT32 _ = Right $ Just "Prelude.Maybe Prelude.UInt"

      ptype _ FieldDescriptorProto_Type_TYPE_ENUM (Just tname) = Right $ Just $ "Prelude.Maybe " <> mkFieldType "" tname

      ptype _ FieldDescriptorProto_Type_TYPE_ENUM _ = Left "Failed genFieldRecord missing FieldDescriptorProto type_name"

      ptype _ FieldDescriptorProto_Type_TYPE_SFIXED32 _ = Right $ Just "Prelude.Maybe Int"

      ptype _ FieldDescriptorProto_Type_TYPE_SFIXED64 _ = Right $ Just "Prelude.Maybe (Prelude.Long Prelude.Signed)"

      ptype _ FieldDescriptorProto_Type_TYPE_SINT32 _ = Right $ Just "Prelude.Maybe Int"

      ptype _ FieldDescriptorProto_Type_TYPE_SINT64 _ = Right $ Just "Prelude.Maybe (Prelude.Long Prelude.Signed)"

      ptype _ FieldDescriptorProto_Type_TYPE_GROUP _ = Left "Failed genFieldRecord GROUP not supported"

    genFieldRecord _ _ = Left "Failed genFieldRecord missing FieldDescriptorProtocol name or number or label or type"
  let
    genMessageExport :: ScopedMsg -> Resp String
    genMessageExport (ScopedMsg namespace (DescriptorProto { name: Just msgName, oneof_decl, field })) =
      ( Right
          $ tname
          <> "(..), "
          <> tname
          <> "Row, "
          <> tname
          <> "R, parse"
          <> tname
          <> ", put"
          <> tname
          <> ", default"
          <> tname
          <> ", mk"
          <> tname
          <> ", merge"
          <> tname
      )
        <> (map (String.joinWith "") (traverse genOneofExport oneof_decl_fields))
      where
      oneof_decl_fields = selectOneofFields oneof_decl field

      tname = mkTypeName $ namespace <> [ msgName ]

      genOneofExport (Tuple (OneofDescriptorProto { name: Just oname }) _) = Right $ ", " <> mkTypeName (namespace <> [ msgName, oname ]) <> "(..)"

      genOneofExport _ = Left "Failed genMessageExport missing OneofDescriptorProto name" -- error, no oname

    genMessageExport _ = Left "Failed genMessageExport missing DescriptorProto name" -- error, no name
  -- | We need to wrap our structural record types in a nominal
  -- | data type so that we can nest records, otherwise we get
  -- | https://github.com/purescript/documentation/blob/master/errors/CycleInTypeSynonym.md
  -- | And so that we can assign instances.
  let
    genMessage :: ScopedMsg -> Resp String
    genMessage (ScopedMsg nameSpace (DescriptorProto { name: Just msgName, field, oneof_decl })) =
      let
        tname = mkTypeName $ nameSpace <> [ msgName ]

        oneof_decl_fields = selectOneofFields oneof_decl field

        fields_singular :: Array FieldDescriptorProto -- the `field` array restricted to fields which are not in a Oneof,
        -- but including fields which are in an optional synthetic Oneof
        fields_singular =
          catMaybes $ field
            <#> case _ of
                f@(FieldDescriptorProto { proto3_optional: Just true }) -> Just f
                (FieldDescriptorProto { oneof_index: Just _ }) -> Nothing
                f -> Just f
      in
        map (String.joinWith "\n")
          $ sequence
              [ Right $ "\ntype " <> tname <> "Row ="
              , Right "  ( "
                  <> ( map (String.joinWith "\n  , ")
                        $ ( (catMaybes <$> traverse (genFieldRecord nameSpace) fields_singular)
                              <> (traverse (genFieldRecordOneof (nameSpace <> [ msgName ])) oneof_decl_fields)
                              <> Right [ "__unknown_fields :: Array Prelude.UnknownField" ]
                          )
                    )
              , Right "  )"
              , Right $ "type " <> tname <> "R = Record " <> tname <> "Row"
              , Right $ "newtype " <> tname <> " = " <> tname <> " " <> tname <> "R"
              , Right $ "derive instance generic" <> tname <> " :: Prelude.Generic " <> tname <> " _"
              , Right $ "derive instance newtype" <> tname <> " :: Prelude.Newtype " <> tname <> " _"
              , Right $ "derive instance eq" <> tname <> " :: Prelude.Eq " <> tname
              -- https://github.com/purescript/purescript/issues/2975#issuecomment-313650710
              , Right $ "instance show" <> tname <> " :: Prelude.Show " <> tname <> " where show x = Prelude.genericShow x"
              , Right ""
              , Right $ "put" <> tname <> " :: forall m. Prelude.MonadEffect m => " <> tname <> " -> Prelude.PutM m Prelude.Unit"
              , Right $ "put" <> tname <> " (" <> tname <> " r) = do"
              , map (String.joinWith "\n")
                  $ (traverse (genFieldPut nameSpace) fields_singular)
                  <> (sequence $ map (genOneofPut (nameSpace <> [ msgName ])) oneof_decl_fields)
              , Right "  Prelude.traverse_ Prelude.putFieldUnknown r.__unknown_fields"
              , Right ""
              , Right $ "parse" <> tname <> " :: forall m. Prelude.MonadEffect m => Prelude.MonadRec m => Int -> Prelude.ParserT Prelude.DataView m " <> tname
              , Right $ "parse" <> tname <> " length = Prelude.label \"" <> msgName <> " / \" $"
              , Right $ "  Prelude.parseMessage " <> tname <> " default" <> tname <> " parseField length"
              , Right " where"
              , Right "  parseField"
              , Right "    :: Prelude.FieldNumberInt"
              , Right "    -> Prelude.WireType"
              , Right $ "    -> Prelude.ParserT Prelude.DataView m (Prelude.Builder " <> tname <> "R " <> tname <> "R)"
              , map (String.joinWith "\n") (traverse (genFieldParser (nameSpace <> [ msgName ]) oneof_decl) field)
              , Right "  parseField fieldNumber wireType = Prelude.parseFieldUnknown fieldNumber wireType"
              , Right ""
              , Right $ "default" <> tname <> " :: " <> tname <> "R"
              , Right $ "default" <> tname <> " ="
              , Right "  { "
                  <> ( map (String.joinWith "\n  , ")
                        ( (traverse genFieldDefault fields_singular)
                            <> (traverse genFieldDefaultOneof oneof_decl_fields)
                            <> Right [ "__unknown_fields: []" ]
                        )
                    )
              , Right "  }"
              , Right ""
              , Right $ "mk" <> tname <> " :: forall r1 r3. Prelude.Union r1 " <> tname <> "Row r3 => Prelude.Nub r3 " <> tname <> "Row => Record r1 -> " <> tname
              , Right $ "mk" <> tname <> " r = " <> tname <> " $ Prelude.merge r default" <> tname
              , map (String.joinWith "\n")
                  $ (sequence $ map (genTypeOneof (nameSpace <> [ msgName ])) oneof_decl_fields)
                  <> (sequence $ map (genIsDefaultOneof (nameSpace <> [ msgName ])) oneof_decl_fields)
                  <> (sequence $ map (genOneofMerge (nameSpace <> [ msgName ])) oneof_decl_fields)
              , Right $ "merge" <> tname <> " :: " <> tname <> " -> " <> tname <> " -> " <> tname
              , Right $ "merge" <> tname <> " (" <> tname <> " l) (" <> tname <> " r) = " <> tname
              , Right "  { "
                  <> ( map (String.joinWith "\n  , ")
                        ( (traverse genFieldMerge fields_singular)
                            <> (traverse (genFieldMergeOneof (nameSpace <> [ msgName ])) oneof_decl_fields)
                            <> Right [ "__unknown_fields: r.__unknown_fields <> l.__unknown_fields" ]
                        )
                    )
              , Right "  }"
              , Right ""
              ]

    genMessage _ = Left "Failed genMessage no DescriptorProto name"
  contents <-
    sequence
      [ Right $ "-- | Generated by __purescript-protobuf__ from file `" <> fromMaybe "<unknown>" fileName <> "`"
      , Right $ "module " <> (String.joinWith "." ((map mkModuleName packageName))) <> "." <> mkModuleName baseName
      , Right "( " <> (map (String.joinWith "\n, ") ((traverse genMessageExport messages) <> (traverse genEnumExport enums)))
      , Right
          """)
where
import Protobuf.Prelude
import Protobuf.Prelude as Prelude
"""
      ]
      <> (traverse genImport dependency)
      <> Right [ "\n" ]
      <> (traverse genMessage messages)
      <> (traverse genEnum enums)
      <> Right [ "\n" ]
  Right
    $ CodeGeneratorResponse_File
        { name: Just fileNameOut
        , insertion_point: Nothing
        , content: Just $ String.joinWith "\n" contents
        , generated_code_info: Nothing
        , __unknown_fields: []
        }
  where
  mkTypeName :: Array String -> String
  mkTypeName ns = String.joinWith "_" $ map capitalize ns

  capitalize :: String -> String
  capitalize s = String.toUpper (String.take 1 s) <> String.drop 1 s

  decapitalize :: String -> String
  decapitalize s = String.toLower (String.take 1 s) <> String.drop 1 s

  -- | underscores and primes are not allowed in module names
  -- | https://github.com/purescript/documentation/blob/master/errors/ErrorParsingModule.md
  mkModuleName :: String -> String
  mkModuleName n = capitalize $ illegalDelete $ underscoreToUpper n
    where
    underscoreToUpper :: String -> String
    underscoreToUpper = case String.Regex.regex "_([a-z])" flag of
      Left _ -> identity
      Right patt -> String.Regex.replace' patt toUpper

    toUpper _ [ x ] = String.toUpper x

    toUpper x _ = x

    flag =
      String.Regex.Flags.RegexFlags
        { global: true
        , ignoreCase: false
        , multiline: false
        , sticky: false
        , unicode: true
        }

    illegalDelete :: String -> String
    illegalDelete =
      String.replaceAll (String.Pattern.Pattern "_") (String.Pattern.Replacement "")
        <<< String.replaceAll (String.Pattern.Pattern "'") (String.Pattern.Replacement "1")

  -- | Pull all of the enums out of of the nested messages and bring them
  -- | to the top, with their namespace.
  flattenEnums :: NameSpace -> Array DescriptorProto -> Array (Resp ScopedEnum)
  flattenEnums namespace msgarray = concatMap go msgarray
    where
    go :: DescriptorProto -> Array (Resp ScopedEnum)
    go (DescriptorProto { name: Just msgName, nested_type, enum_type: msgEnums }) =
      (Right <$> ScopedEnum (namespace <> [ msgName ]) <$> msgEnums)
        <> flattenEnums (namespace <> [ msgName ]) nested_type

    go _ = [ Left "Failed flattenEnums missing DescriptorProto name" ]

  -- The `oneof_decl` array annotated with which fields belong to it,
  -- excluding optional synthetic Oneofs.
  selectOneofFields :: Array OneofDescriptorProto -> Array FieldDescriptorProto -> Array (Tuple OneofDescriptorProto (Array FieldDescriptorProto))
  selectOneofFields oneof_decl field =
    catMaybes
      $ flip Array.mapWithIndex oneof_decl \i o -> do
          let
            fields =
              flip Array.filter field
                $ case _ of
                    (FieldDescriptorProto { oneof_index: Just j })
                      | i == j -> true
                    _ -> false
          case fields of
            [ FieldDescriptorProto { proto3_optional: Just true } ] -> Nothing
            _ -> Just $ Tuple o fields

  genEnumExport :: ScopedEnum -> Resp String
  genEnumExport (ScopedEnum namespace (EnumDescriptorProto { name: Just eName })) = Right $ (mkTypeName $ namespace <> [ eName ]) <> "(..)"

  genEnumExport _ = Left "Failed genEnumExport missing EnumDescriptorProto name"

  genEnum :: ScopedEnum -> Resp String
  genEnum (ScopedEnum namespace (EnumDescriptorProto { name: Just eName, value })) = do
    let
      tname = mkTypeName $ namespace <> [ eName ]
    enumConstruct <- traverse genEnumConstruct value
    enumTo <- traverse genEnumTo value
    enumFrom <- traverse genEnumFrom value
    Right $ String.joinWith "\n"
      $ [ "\ndata " <> tname
        , "  = " <> String.joinWith "\n  | " enumConstruct
        , "derive instance generic" <> tname <> " :: Prelude.Generic " <> tname <> " _"
        , "derive instance eq" <> tname <> " :: Prelude.Eq " <> tname
        , "instance show" <> tname <> " :: Prelude.Show " <> tname <> " where show = Prelude.genericShow"
        , "instance ord" <> tname <> " :: Prelude.Ord " <> tname <> " where compare = Prelude.genericCompare"
        , "instance bounded" <> tname <> " :: Prelude.Bounded " <> tname
        , " where"
        , "  bottom = Prelude.genericBottom"
        , "  top = Prelude.genericTop"
        , "instance enum" <> tname <> " :: Prelude.Enum " <> tname
        , " where"
        , "  succ = Prelude.genericSucc"
        , "  pred = Prelude.genericPred"
        , "instance boundedenum" <> tname <> " :: Prelude.BoundedEnum " <> tname
        , " where"
        , "  cardinality = Prelude.genericCardinality"
        ]
      <> enumTo
      <> [ "  toEnum _ = Prelude.Nothing" ]
      <> enumFrom
    where
    genEnumConstruct (EnumValueDescriptorProto { name: Just name }) = Right $ mkEnumName name

    genEnumConstruct arg = Left $ "Failed genEnumConstruct\n" <> show arg

    genEnumTo (EnumValueDescriptorProto { name: Just name, number: Just number }) = Right $ "  toEnum " <> show number <> " = Prelude.Just " <> mkEnumName name

    genEnumTo arg = Left $ "Failed genEnumTo\n" <> show arg

    genEnumFrom (EnumValueDescriptorProto { name: Just name, number: Just number }) = Right $ "  fromEnum " <> mkEnumName name <> " = " <> show number

    genEnumFrom arg = Left $ "Failed genEnumFrom\n" <> show arg

    mkEnumName name = mkTypeName $ namespace <> [ eName ] <> [ name ]

  genEnum _ = Left $ "Failed genEnum no EnumDescriptorProto name"

  -- | Pull all of the nested messages out of of the messages and bring them
  -- | to the top, with their namespace.
  flattenMessages :: NameSpace -> Array DescriptorProto -> Array (Resp ScopedMsg)
  flattenMessages namespace msgarray = concatMap go msgarray
    where
    go :: DescriptorProto -> Array (Resp ScopedMsg)
    go (DescriptorProto r@{ name: Just msgName, nested_type }) =
      [ Right $ ScopedMsg namespace (DescriptorProto r) ]
        <> flattenMessages (namespace <> [ msgName ]) nested_type

    go _ = [ Left "Failed flattenMessages missing DescriptorProto name" ]

  -- https://developers.google.com/protocol-buffers/docs/proto3#oneof_features
  -- “A oneof cannot be repeated.”
  -- See also genFieldRecord
  genFieldRecordOneof :: NameSpace -> (Tuple OneofDescriptorProto (Array FieldDescriptorProto)) -> Resp String
  genFieldRecordOneof nameSpace (Tuple (OneofDescriptorProto { name: Just fname }) _) =
    Right
      $ decapitalize fname
      <> " :: Prelude.Maybe "
      <> (String.joinWith "_" $ map capitalize $ nameSpace <> [ fname ])

  genFieldRecordOneof _ _ = Left "Failed genFieldRecordOneof missing OneofDescriptorProto name"

  genFieldDefault :: FieldDescriptorProto -> Resp String
  genFieldDefault ( FieldDescriptorProto
      { name: Just name'
    , label: Just flabel
    }
  ) = Right $ fname <> ": " <> dtype flabel
    where
    fname = decapitalize name'

    dtype FieldDescriptorProto_Label_LABEL_REPEATED = "[]"

    dtype _ = "Prelude.Nothing"

  genFieldDefault _ = Left "Failed genFieldDefault missing FieldDescriptorProto name or label"

  -- https://developers.google.com/protocol-buffers/docs/proto3#oneof_features
  -- “A oneof cannot be repeated.”
  genFieldDefaultOneof :: (Tuple OneofDescriptorProto (Array FieldDescriptorProto)) -> Resp String
  genFieldDefaultOneof (Tuple (OneofDescriptorProto { name: Just oname }) _) = Right $ decapitalize oname <> ": Prelude.Nothing"

  genFieldDefaultOneof _ = Left "Failed genFieldDefaultOneof missing name"
