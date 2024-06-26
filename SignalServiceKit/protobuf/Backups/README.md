# Backup Proto

The Backup protos are generated using [Wire](https://github.com/square/wire),
in contrast with the rest of the Signal-iOS protos which use (at the time of
writing) a combination of
[Swift-Protobuf](https://github.com/apple/swift-protobuf/) and bespoke
code-generation in [ProtoWrappers.py](../../../Scripts/protos/ProtoWrappers.py).

Using `Wire` for Backups obviates the need for updates to `ProtoWrappers.py`,
and the models generated by `Wire` are easier to work with than those generated
by `ProtoWrappers.py`.

Additionally, the `Wire`-generated models expose `optional` protobuf fields as
`Optional` values in Swift. This is in contrast to `Swift-Protobuf`, which
exposes those fields as non-`Optional` (with a default value returned if none is
present) with `hasField` properties allowing the caller to inspect if a value
was explicitly set. While the `Swift-Protobuf` approach is arguably closer to
the raw behavior of protobufs, the `Wire` approach more directly supports the
type-safe calling patterns we want to use in code.

## How to generate models

See [compile-backups-proto-with-wire](../../../Scripts/protos/compile-backups-proto-with-wire).
That script reads the `Backup.proto` file in this directory, downloads the
`Wire` (if necessary), and runs it to generate models to the right place.

## Special considerations when using `Wire`

`Wire` does not support adding a prefix to type names for namespacing purposes.
To that end, ensure the names of `message`, `enum`, etc. types in
`Backup.proto` (or other protos down the line) are namespaced within the proto
itself; for example, prefer `message BackupProtoAccountData` to `message AccountData`.
