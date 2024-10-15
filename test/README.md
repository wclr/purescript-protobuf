# Unit Tests

`unittest_proto3_optional.proto` is copied from
`$(dirname $(which protoc))/../src/google/protobuf/unittest_proto3_optional.proto`

To test purescript-protobuf, run `nix develop` from the top level directory
of the repo, then:

```console
spago -x spago-plugin.dhall build
```
```console
protoc --purescript_out=./test/generated test/*.proto
```
```console
spago -x spago-test.dhall test
```

# Benchmarks

To run the benchmarks, run `nix develop` from the top level directory, then:

```console
spago -x spago-test.dhall run --main Test.Bench
```

