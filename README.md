# Buck2/nextest artifact handoff

This repository proves a local Buck2-to-nextest artifact boundary. Buck2 builds a native Rust test executable and emits a strict serialized manifest. The adapter stages only those declared inputs, synthesizes the documented Cargo/nextest metadata shape, runs nextest, and exports nextest's JUnit XML before removing its private root.

## Prerequisites

- Buck2 with the bundled prelude `rust_test` rule.
- Rust and Cargo.
- `cargo-nextest` 0.9.143, exposing metadata/remap, filterset, output, profile, and no-tests controls used here.
- Python 3.11+ for strict manifest, metadata, XML-test, baseline tooling, and timeout profile assertions.

No toolchain provisioning is included; this first declared-output rule uses the checked-in local tool-path configuration and is not portable or hermetic. `setsid` is needed only for process-group signal-cleanup coverage. The current macOS host does not provide it, so that test reports the prerequisite blocker rather than claiming unsupported coverage.

## Canonical invocation

`buck-artifact` is the only supported adapter mode:

```text
adapter.sh buck-artifact \
  --artifact PATH \
  --manifest PATH \
  --validator PATH \
  --cargo-baseline PATH \
  --binary-baseline PATH \
  --tests-baseline PATH \
  --junit-report PATH \
  [--scenario pass|fail|ignored|filtered|no-tests|timeout]
```

Every input and the report destination are validated before any `cargo nextest` help probe or dispatch. A relative report path is resolved against the adapter invocation directory. Existing parent components must be real directories, not symlinks; the destination may be absent or an existing regular file, but may not be a directory or symlink. Parents are not created. Export uses a mode-0600 same-directory temporary and atomic replacement, so the last successful export wins.

The adapter configures a private `ci` nextest profile with `junit.path = "junit.xml"`. For the ignored-only scenario it also sets `report-skipped = "ignored"`; nextest 0.9.143 requires `--no-tests pass` because the selected test is skipped rather than runnable. Other closed scenarios use the default skipped-report policy so filtered-out cases remain absent. The adapter validates XML only to reject a broken internal report; it copies the nextest bytes unchanged and does not add a summary protocol.

## Supported results

The bounded result contract follows nextest's process boundary:

- `pass`: selects `pass_case`, exports successful JUnit, returns `0`.
- `fail`: selects `fail_case`, exports a `<failure>`, returns `100`.
- `ignored`: selects `ignored_case`, exports it as `<skipped>`, returns `0`.
- `filtered`: selects only `pass_case`; `fail_case` and `ignored_case` are absent, returns `0`.
- `no-tests`: uses an unmatched filter and `--no-tests fail`, returns `4`. If nextest emits no JUnit, the destination may remain absent; XML is never synthesized.
- `timeout`: development/regression coverage selects `timeout_case` with a closed one-second nextest slow-timeout profile; the completed timeout is ordinary status `100` with a JUnit `<failure>` and no timeout-specific marker. This is not a general timeout configuration API.

Completed pass and test-failure runs require a valid exported report. Other setup/metadata/unknown nonzero statuses retain their raw nextest status and export a report if one exists. A required post-dispatch verification/export failure returns adapter status `3` and prints the raw nextest status; pre-dispatch validation returns `2`. Human-readable nextest output remains diagnostic, not a protocol.

A completed timeout, if later observed, remains nextest's ordinary test-failure class and JUnit `<failure>`; this milestone defines no timeout-specific XML marker. Process interruption, abort, and cancellation have no stable adapter classification and remain deferred.

## Build and test

The fixed declared-output build surface runs the successful `pass_case` contract as a keyed, local-only Buck action:

```sh
buck2 build //:nextest_buck_artifact_junit --show-output
# buck-out/.../__nextest_buck_artifact_junit__/junit.xml
buck2 build //:nextest_buck_artifact_junit
```

The JUnit file is owned by Buck and is available to `$(location :nextest_buck_artifact_junit)` consumers. Identical declared inputs may reuse the keyed output; `buck clean` removes it. This milestone does not promise failed-build report retrieval, configurable filters/profiles/retries, remote execution/cache upload, or persistent nextest rerun records. Use the existing `buck2 test` surface below for fresh execution and failure/flaky status behavior.

```sh
buck2 build //:buck2_nextest_rust_test //:buck2_nextest_artifact_manifest
buck2 test --test-executor-stdout=- --test-executor-stderr=- \
  //:nextest_buck_artifact \
  //:nextest_buck_artifact_expected_failure \
  //:nextest_buck_artifact_status_ignored \
  //:nextest_buck_artifact_status_filtered \
  //:nextest_buck_artifact_status_no-tests \
  //:nextest_buck_artifact_status_timeout
buck2 test --test-executor-stdout=- --test-executor-stderr=- //:legacy_path_absent
buck2 test --test-executor-stdout=- --test-executor-stderr=- //:documentation_smoke
```

The pass scenario also proves manifest-driven cwd/environment, runtime staging, source denial/no nested build, executable digest equality, and once-only private-root cleanup. Destination tests prove pre-dispatch rejection, existing-file replacement, paths with spaces, byte-identical pass-through, and status-3 precedence for forced export failures after raw `0` and `100`.

## Manifest and baseline distinction

Schema version 1 is experimental/pre-release and evolves in place. `artifact.test_cases` is exactly this ordered record list:

```json
[
  {"name": "pass_case", "ignored": false},
  {"name": "fail_case", "ignored": false},
  {"name": "ignored_case", "ignored": true},
  {"name": "timeout_case", "ignored": false}
]
```

Ordering and exact fields are significant. Synthetic Buck metadata is derived from these four records.

The checked-in Cargo fixture and `tools/capture_cargo_nextest_baseline.sh` are observation/regeneration inputs only, not a supported execution path or runtime resource. Their normalized observation intentionally remains two cases (`pass_case`, `fail_case`) across two Cargo integration-test binaries plus one library binary. See [`docs/baseline-and-manifest.md`](docs/baseline-and-manifest.md) for the strict contract and [`docs/nextest-buck2-roadmap.md`](docs/nextest-buck2-roadmap.md) for completed and deferred phases.

## Scope boundary

This milestone does not add an adapter-owned XML/result schema, parse human output, use experimental libtest JSON, define an internal event protocol, or cover retries, remote execution, generated outputs beyond the existing contract, shared libraries, direct nextest embedding, native provider promotion, or stable abort/cancel mapping.
