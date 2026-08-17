# Cargo baseline and Buck2 artifact manifest

This document separates two contracts: a captured Cargo/nextest observation used to shape synthetic metadata, and the supported Buck artifact execution contract. The observation is not a promise that nextest's list JSON is a stable upstream schema.

## Baseline observation and regeneration

```sh
CARGO_NET_OFFLINE=true ./tools/capture_cargo_nextest_baseline.sh baseline/normalized
```

The capture script copies `fixture/` into an isolated temporary workspace and records Cargo metadata, nextest binary-only JSON, nextest test-list JSON, exact tool versions, target/platform information, and a fixture digest. The fixture and capture script are observation/regeneration inputs only. They are not an adapter execution mode and are not resources of the canonical runner.

Normalized paths use `<WORKSPACE>` and `<TARGET_DIR>`. The observation intentionally remains:

- `tests.json` test count `2`;
- observed cases `pass_case` and `fail_case`;
- two Cargo integration-test binaries (`fail_case`, `pass_case`) plus one library binary.

Those facts guard the captured metadata shape. They are not authoritative for Buck testcase identity.

Official references include [machine-readable list](https://nexte.st/docs/machine-readable/list/), [archive/reuse](https://nexte.st/docs/ci-features/archiving/), [running](https://nexte.st/docs/running/), and [JUnit](https://nexte.st/docs/machine-readable/junit/). The installed nextest version is captured because the list JSON is not published as a general compatibility schema.

## Schema-v1 Buck contract

`artifact-manifest.example.json` documents the experimental, pre-release schema version 1. It supports exactly one local native Buck Rust test artifact:

- package `buck2-nextest-buck-artifact`;
- binary ID/name `buck2_nextest_rust_test`;
- target kind `test`;
- exact ordered testcase records:

```json
[
  {"name": "pass_case", "ignored": false},
  {"name": "fail_case", "ignored": false},
  {"name": "ignored_case", "ignored": true},
  {"name": "timeout_case", "ignored": false}
]
```

Each testcase value must be a record with exactly `name` and `ignored`; names must be nonempty strings and unique, and ignored values must be JSON booleans. Missing, extra, duplicate, reordered, mistyped, or unknown fields are rejected. The supported binary identity and the ordered records must match exactly. Synthetic test metadata derives its testcase map, ignored flags, and count `4` from the validated records.

The manifest also contains rooted relative executable, working-directory, and static-runtime-input paths; a manifest-driven string environment; target triple/features; and an empty `build.generated_outputs`. Unknown versions and extra/missing top-level fields fail closed. Paths cannot be absolute, contain unsafe components, traverse symlinks, overlap protected paths, or resolve outside the private root. Adapter-owned environment and path names are rejected.

Schema v1 is intentionally evolved in place while it remains repository-local and pre-release. A future incompatible contract after stabilization or external consumption uses a new version.

## Canonical local handoff

`adapter.sh buck-artifact` is the only supported execution interface. It requires the declared artifact, manifest, validator, three baseline metadata files, and `--junit-report PATH`. Before any cargo-nextest help probe or dispatch, it validates all inputs and resolves a relative report path against the invocation cwd. Existing destination parents must be non-symlink directories; the destination may be absent or an existing regular file, but not a symlink or directory. Parent directories are not created.

The adapter stages every declared runtime input under one private root, validates the manifest before and after staging, applies the manifest environment, synthesizes metadata, verifies declared/staged executable SHA-256 equality, and uses source-denial wrappers to prove no nested Cargo build or compiler invocation occurs. `cargo nextest list` is machine-readable discovery validation only, not a result protocol.

For runs, a private `.config/nextest.toml` defines profile `ci` and `junit.path = "junit.xml"`. The ignored-only scenario adds `report-skipped = "ignored"` and `--no-tests pass`, making the selected ignored case appear as `<skipped>` while the run remains successful. The closed timeout regression scenario additionally uses `slow-timeout = { period = "1s", terminate-after = 1, grace-period = "0s" }` in the parent `ci` profile, selects only `timeout_case`, and expects status `100` with one JUnit `<failure>` and no timeout-specific marker. Other scenarios use the default skipped-report policy, so filtered-out cases remain absent. This behavior is verified against captured nextest 0.9.143 and is not silently generalized to other versions.

Nextest writes JUnit beneath the private workspace. After the child exits, the adapter saves its status, verifies any emitted report as XML, copies the bytes to a mode-0600 same-directory temporary beside the caller destination, and atomically renames it. The report therefore survives private-root cleanup, and the adapter does not rewrite or add XML elements. Byte-digest tests compare a trusted private nextest report with the exported file.

## Status and failure precedence

The bounded process contract is:

- success `0` with required JUnit for completed pass runs;
- no tests selected `4` for the explicit unmatched-filter/`--no-tests fail` scenario, with no synthesized XML and an absent destination permitted if nextest emits none;
- test failure `100`, including a completed timeout represented by nextest as ordinary failure, with required JUnit;
- setup, metadata, and unknown nonzero failures retain their raw status and export JUnit if one exists.

If required verification/export fails after dispatch, the adapter returns `3`, prints `raw nextest status=<status>` plus the export error, and cleans once. Pre-dispatch validation returns `2` without a help probe or dispatch. Human-readable output remains diagnostic only. No adapter-owned summary, human-output parser, experimental libtest JSON, internal event stream, timeout-specific XML marker, or invented abort code exists.

Process interruption, abort, and cancellation have no stable adapter classification in this milestone. Process-group cleanup coverage requires `setsid`; on this macOS host its absence is reported as a prerequisite blocker rather than claimed as coverage.

## Deferred scope

Retries, groups, remote-like and remote execution, generated outputs beyond the current empty contract, shared libraries, direct embedding, native provider promotion, richer event protocols, and stable abort/cancel mapping remain later work.
