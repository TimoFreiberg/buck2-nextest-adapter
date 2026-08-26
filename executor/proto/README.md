# Pinned Buck test protocol

This directory contains the complete protocol input closure used by the opt-in
executor. The source files are copied byte-for-byte from Buck commit
`1560aca2002865cd73d7cafb22c705cfb640b2bc`, observed as
`buck2 2026-07-14-1560aca2002865cd73d7cafb22c705cfb640b2bc`:

- `upstream/buck2_test_proto/test.proto`
- `upstream/buck2_data/data.proto`
- `upstream/buck2_data/error.proto`
- `upstream/buck2_host_sharing_proto/host_sharing.proto`

The generated Rust files in `../src/proto/gen` are produced by the locked
`executor/codegen` package using `tonic-prost-build 0.14.6`, `prost-build
0.14.4`, and `protoc-bin-vendored 3.2.0`. Generation uses the vendored
protoc and its matching Google well-known-type include directory; it never
consults a PATH `protoc`.

The source SHA-256 digests are:

```text
55863862efa5c2fc5860dd955f5380d79c72215a5ad21e14e55550b5068fcfe4  upstream/buck2_data/data.proto
c7bd1cc46050504140637bd456ada02cb1a25424c876eec0d1612e1f04a25a44  upstream/buck2_data/error.proto
685a79f5e488a3b69fd1ea310b2b7106368c69e52d91a9bc47a281db2a2f8210  upstream/buck2_host_sharing_proto/host_sharing.proto
0a0418b867d2ec45f7a8e0ca72030e7919e2ac5ab00598f8e16ecf45458572b0  upstream/buck2_test_proto/test.proto
```

Regenerate or check the committed bindings with:

```sh
./executor/proto/regenerate.sh --check
```

The script creates a temporary output directory and compares every generated
file before changing anything. A platform without a `protoc-bin-vendored`
binary or include directory fails with a diagnostic; ambient tooling is not a
fallback. A Buck upgrade requires updating the source commit/version and all
source/binding digests, regenerating, and rerunning the pinned FD/TCP lifecycle,
argv, output, cancellation, and failure tests before support is claimed.

The executor intentionally omits Buck's Rust workspace, DownwardApi, event
forwarding, remote output transport, and future schema-v2 nextest dispatch.
