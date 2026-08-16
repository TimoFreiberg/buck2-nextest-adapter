# Cargo baseline and Buck2 artifact manifest

This document records the first local compatibility boundary. It is an
observation of the installed Cargo/nextest pair, not a promise that nextest's
machine-readable JSON is a stable upstream schema.

## Baseline capture

Run the reproducible capture from a clean checkout:

```sh
CARGO_NET_OFFLINE=true ./tools/capture_cargo_nextest_baseline.sh baseline/normalized
```

The command copies `fixture/` into a fresh temporary workspace, sets a fresh
`CARGO_TARGET_DIR`, captures Cargo/rustc/cargo-nextest/Buck2 versions and
`rustc -vV`, then records:

- `cargo metadata --locked --format-version 1`;
- `cargo nextest list --list-type binaries-only --message-format json`;
- `cargo nextest list --message-format json`.

`CARGO_NET_OFFLINE` defaults to `true`; the fixture is dependency-free and the
lockfile is required. The command does not write the fixture or its source
inputs. `fixture-digest.sha256` is a digest over the checked-in fixture names
and bytes, and is a regression guard rather than a Cargo checksum.

The normalized files replace temporary workspace and target roots with
`<WORKSPACE>/fixture` and `<TARGET_DIR>`. The Rust toolchain libdir is recorded
as a runtime field but remains host-specific and is not used as a checked-in
absolute path. Stable identity fields are the package/target kind, binary
ID/name, binary path shape, working directory semantics, test-case names,
platform triple/features, linked paths, build-script output directories, and
environment assumptions. The current baseline observes two test binaries,
`fail_case` and `pass_case`, and two test cases.

Official references:

- [nextest machine-readable list](https://nexte.st/docs/machine-readable/list/)
- [nextest archive/reuse](https://nexte.st/docs/ci-features/archiving/)
- [nextest running](https://nexte.st/docs/running/)

Those pages document the command surface and field families, but nextest does
not publish the JSON as a general compatibility schema. The installed version
is therefore captured alongside the normalized observation.

## Version 1 manifest

`artifact-manifest.example.json` is the checked-in shape. Version 1 supports
exactly one local native Buck2 Rust test artifact:

- package `buck2-nextest-buck-artifact`;
- binary ID/name `buck2_nextest_rust_test`;
- target kind `test`;
- test cases `pass_case` and `fail_case`;
- executable, working directory, runtime inputs, and generated outputs as
  relative paths below one private staging root;
- declared environment and target triple/features.

Unknown schema versions and extra or missing fields fail closed. Paths cannot
be absolute, contain `.`/`..`, be missing, be symlinks, or resolve outside the
private root. The Python 3 helper uses only the standard library and is
Buck-declared development/test tooling; Python is not part of the Rust test
artifact or a future nextest runtime dependency.

Cargo's two integration binaries are deliberately baseline observations. The
Buck contract maps their test-case union into the one synthetic Buck binary;
it does not preserve the incidental Cargo target split.

## Local handoff

The `buck-artifact` adapter mode consumes a declared Buck output, stages it
under the private root, validates the manifest, synthesizes the Cargo-shaped
metadata, and supplies that metadata to `cargo nextest list` and `run` with
`--cargo-metadata`, `--binaries-metadata`, `--target-dir-remap`,
`--workspace-remap`, and the installed `--build-dir-remap` surface. It does not
run Cargo build/test to produce the executable. It compares SHA-256 digests of
the declared Buck output and staged executable and rejects Cargo target-dir
provenance.

The installed nextest 0.9.143 exposes the required flags. The adapter's
Buck-artifact path moves the checked-in fixture aside for its private lifetime,
uses a private Cargo home/manifest root, and supplies only synthetic metadata.
A true no-discovery claim still requires source-denial wrappers around the
installed Cargo/nextest dispatch to pass; absence of a printed build line alone
is not evidence. The lifecycle signal scenario also requires `setsid` (or an
equivalent launcher) to track a process group. The current macOS host does not
provide `setsid` on `PATH`, so that scenario is a reported prerequisite blocker
rather than a weaker cleanup implementation.

Retries, timeouts, groups, JUnit/status mapping, remote-like or remote
execution, direct nextest embedding, native provider promotion, and richer
event protocols remain outside this boundary.
