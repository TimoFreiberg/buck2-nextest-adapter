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

`nextest_buck_artifact buck-artifact --build-mode` is the only supported execution interface. It requires the declared artifact, manifest, three baseline metadata files, cargo-nextest argv, runtime/bundle inputs, and `--junit-report PATH`. Before any nextest help probe or dispatch, the Rust runner validates all inputs. Direct/ambient mode, Python/Cargo helpers, source-denial wrappers, PATH lookup, and `/tmp` scratch fallback are unsupported. Existing destination parents must be non-symlink directories; the destination may be absent or an existing regular file, but not a symlink or directory. Parent directories are not created.

The adapter stages every declared runtime input under one private root, validates the manifest before and after staging, applies the manifest environment, synthesizes metadata, verifies declared/staged executable SHA-256 equality, and invokes only the declared cargo-nextest argv with offline/sanitized environment. `nextest list` is machine-readable discovery validation only, not a result protocol; no nested Cargo build or compiler lookup is available to the action.

For runs, a private `.config/nextest.toml` defines the selected safe profile and `junit.path = "junit.xml"`. The five controls are `profile` (default `ci`), one non-empty `filter` (default `test(=pass_case)`), `no_tests` (`auto|pass|warn|fail`, default `auto`), `report_skipped` (`default|ignored`, default `default`), and `timeout_seconds` (`0..86400`, default `0`). A positive timeout adds only `slow-timeout = { period = "<N>s", terminate-after = 1, grace-period = "0s" }`; ignored reporting adds only `report-skipped = "ignored"`. Profile names match `[A-Za-z0-9][A-Za-z0-9_-]*`; `default-*` is syntactically accepted but remains an upstream-owned nextest namespace. Filters are passed as one argv value and never interpolated into TOML or paths. The old scenario switch is removed. The explicit ignored, unmatched-filter, and timeout combinations preserve the existing `<skipped>`, status `4`, and ordinary status `100` semantics against nextest 0.9.143. The timeout regression uses `slow-timeout = { period = "1s", terminate-after = 1, grace-period = "0s" }`; there is no timeout-specific marker.

Nextest writes JUnit beneath the private workspace. After the child exits, the adapter saves its status, verifies any emitted report as XML, copies the bytes to a mode-0600 same-directory temporary beside the caller destination, and atomically renames it. The report therefore survives private-root cleanup, and the adapter does not rewrite or add XML elements. Byte-digest tests compare a trusted private nextest report with the exported file.

## Three distinct result surfaces

The repository intentionally has three different output/result contracts:

1. **Stock `buck2 test`:** Buck owns execution and reports status, stdout, and
   stderr. It does not promise a caller-visible JUnit file for failed tests.
2. **Opt-in project test executor:** `test.v2_test_executor` selects the
   pinned executor for a fresh `buck2 test` invocation. For `ExternalRunnerSpec`
   values with `type = "nextest"`, the executor asks Buck to materialize one
   local declared `junit` directory, injects `BUCK2_NEXTEST_JUNIT_DIR`, validates its unchanged
   `junit.xml`, and exports it into the caller's fresh directory, including on test failure and
   timeout. The executor remains opt-in and is pinned to Buck commit
   `1560aca2002865cd73d7cafb22c705cfb640b2bc`. It owns the enclosing
   `Execute2` transport and report export but does not run cargo-nextest; the
   schema-v2 runner invoked by Buck performs nextest dispatch. Buck's nonzero
   status remains authoritative, and valid reports from other targets can
   survive an infrastructure failure.
3. **Normal build action:** `//:nextest_buck_artifact_junit` declares a fixed
   `junit.xml` build output. That output is available to consumers only when
   the build action succeeds; it is not a failed-test report retrieval API.

## Declared build output and caller-owned test output

`//:nextest_buck_artifact_junit` is a separate normal Buck build action. It declares one successful fixed-name `junit.xml` output under `buck-out`; its five profile/filter/no-tests/report-skipped/timeout attrs are literal action inputs, so result-affecting configurations have distinct action identity. It runs local-preferred with the declared cargo-nextest executable target. Ordinary builds remain local in this checkout; explicit `--remote-only` requires caller-owned supported RE configuration. The launcher target must provide `RunInfo` and is invoked with the fixed `nextest` subcommand. Build mode requires all runtime resources explicitly; it fails closed before probing if any required input is absent. The v1 toolchain bundle extends this with provider-owned direct execution resources, normalized POSIX destinations, checked `sha256:<hex>:<size>` digests, ordered typed environment records (`literal` or `relative_path`), and a non-empty opaque execution identity. Shared libraries and launcher support files are not inferred from PATH or host state; unsafe bundle data fails before probing. Buck supplies `BUCK_SCRATCH_PATH` for private per-run state, and the runner creates one project-relative private child without a direct-mode fallback. Its private synthesized workspace, metadata, target state, and profile-derived intermediate report are per-run scratch and are removed only after the owned process group is drained; no persistent nextest rerun store is created.

The declared `junit.xml` is a successful-build artifact only. A failing nextest result fails the Buck action, so failed declared outputs are not a supported `$(location)`/consumer path. Buck's ordinary failed-action diagnostics are the supported build diagnostics; this contract does not promise failed-output retrieval or a Buck `error_handler`. The adapter still supports a caller-supplied `--junit-report` destination and propagates failure status. This slice does not provide outer `buck2 test` capture, display, or retrieval of that report: `buck2 test` continues to invoke the caller-owned adapter handoff, whose JUnit destination is supplied by the test script and is not a declared output of the test target.

This checkout's deterministic executable fixtures are local convenience configuration for repository tests, not the consumer contract. The relocated/sanitized test proves the declared-input boundary from a different cwd with no ambient launcher/interpreter lookup. The action metadata parser proves selected declared paths and digests in-action; `what-materialized` is best-effort evidence only and may report an observability gap. Declared executable artifacts participate in local action inputs. The action is local-preferred with cache upload disabled; the opt-in remote gate requires caller-owned config/platform inputs and exact remote-submission/materialization evidence, while the self-test is control-flow only. The lifecycle check reports deterministic rebuild behavior and an execution-observability gap rather than claiming a stable cache-hit or `buck clean` policy. Retries, groups, persistent records, arbitrary profile TOML, cache validation, cancellation/descendant teardown, failed-output retrieval, and per-test remote scheduling remain deferred.

## Status and failure precedence

The bounded process contract on supported Linux/macOS hosts is:

- success `0` with required JUnit for completed pass runs;
- no tests selected `4` for the explicit unmatched-filter/`--no-tests fail` combination, with no synthesized XML and an absent destination permitted if nextest emits none;
- test failure `100`, including a completed timeout represented by nextest as ordinary failure, with required JUnit;
- setup, metadata, and unknown nonzero failures retain their raw status and export JUnit if one exists.

If required verification/export fails after dispatch, the adapter returns `3`, prints `raw nextest status=<status>` plus the export error, and cleans once. Pre-dispatch validation returns `2` without a help probe or dispatch. A first HUP/INT/TERM returns `129/130/143` after the owned process group is drained; a wait, group-quiescence, or secure scratch-cleanup failure overrides to `2` and retains the bounded scratch root. Human-readable output remains diagnostic only. No adapter-owned summary, human-output parser, experimental libtest JSON, internal event stream, timeout-specific XML marker, or invented abort code exists.

If the runner receives HUP, INT, or TERM, supported Linux/macOS execution uses a native process group, forwards the first termination signal, waits for the leader, verifies bounded quiescence for observed groups, and cleans scratch only afterward. The pinned Buck executor may terminate the runner before it receives a signal, and nextest may create a separate process group; outer cancellation and descendant teardown are therefore not yet proven. Windows and deliberate session/group escape are outside this guarantee.

## Generic provider contract (schema v2)

The production `nextest_buck_test` rule consumes one `NextestBuckTestBinaryInfo` provider per binary. The provider owns exactly one executable association and its explicitly declared regular-file runtime closure; a target may consume multiple providers. The suite supplies environment through `ExternalRunnerTestInfo`; each record supplies package identity, canonical owner label, binary identity/display name, explicit executable/closure destinations, package-scoped cwd, and opaque platform identity. Record-level environment is not part of schema v2 and strict decoding rejects it.

Semantic uniqueness is `(package identity, canonical owner label, binary identity)`. Generated IDs are reversible `b2n1:p=<encoded>;o=<encoded>;b=<encoded>` values. Encoding preserves UTF-8 bytes, leaves only unreserved ASCII readable, and uses uppercase percent escapes for every other byte. The decoder rejects unsupported versions, empty identities, malformed/lowercase/non-canonical escapes, invalid UTF-8, duplicate fields, and trailing data. Validation rejects symlinks/trees, unsafe or overlapping destinations, duplicate executable associations, undeclared/generated outputs, adapter-owned paths/environment names, and missing identity/platform data before dispatch.

The checked-in `tools/nextest_buck_test_records.json` and `tools/test_semantic_contract.py` fixtures prove same-display and multi-binary identity behavior. They are contract fixtures, not a checked-in test-case list and not a substitute for nextest discovery. The production Buck target stages generated metadata, validates real nextest `list`, runs one real `nextest run`, and publishes nextest's unchanged JUnit bytes through the opt-in executor.

## Deferred scope

Retries, groups, generated outputs beyond the current empty contract, shared libraries, direct embedding, native provider promotion, richer event protocols, cache behavior, and failed-output retrieval remain later work. The production schema-v2 runner cleans up process groups when it receives a signal, but outer Buck cancellation can terminate it before its handler runs and nextest may create a separate group; complete descendant teardown remains deferred. The remote gate does not attest worker-side execution or rule out RE-service deduplication. Required default CI coverage includes the real declared-toolchain production check and the relocated adapter check as repository-level checks, not nested `sh_test`s. Missing relocation or process-inspection prerequisites fail CI with diagnostics before Buck or adapter dispatch. Process-group and live-remote checks remain separately bounded by their documented host/backend requirements.
