# Buck2/nextest artifact handoff

This repository proves a local Buck2-to-nextest artifact boundary. Buck2 builds a native Rust test executable and emits a strict serialized manifest. The adapter stages only those declared inputs, synthesizes the documented Cargo/nextest metadata shape, runs nextest, and exports nextest's JUnit XML before removing its private root.

## Prerequisites

- Buck2 with the bundled prelude `rust_test` rule.
- Rust and Cargo.
- `cargo-nextest` 0.9.143, exposing metadata/remap, filterset, output, profile, and no-tests controls used here.
- Python 3.11+ for strict manifest, metadata, XML-test, baseline tooling, and timeout profile assertions.

No toolchain provisioning is included. Consumers provide Cargo, Python, and the cargo-nextest launcher as executable Buck targets exposing both `DefaultInfo` and `RunInfo`; the launcher is invoked with the fixed `nextest` subcommand. Cargo is declared and keyed for source-denial, but build mode does not dispatch it to compile or rediscover the artifact. This checkout's checked-in deterministic fixtures are local convenience configuration for tests, not a portable tool distribution or remote-ready toolchain. `setsid` is needed only for process-group signal-cleanup coverage. The current macOS host does not provide it, so that test reports the prerequisite blocker rather than claiming unsupported coverage.

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
  [--profile NAME] [--filter EXPRESSION] \
  [--no-tests auto|pass|warn|fail] \
  [--report-skipped default|ignored] [--timeout-seconds N]
```

Every input and the report destination are validated before any `cargo nextest` help probe or dispatch. A relative report path is resolved against the adapter invocation directory. Existing parent components must be real directories, not symlinks; the destination may be absent or an existing regular file, but may not be a directory or symlink. Parents are not created. Export uses a mode-0600 same-directory temporary and atomic replacement, so the last successful export wins.

The adapter defaults to a private `ci` profile, `filter = test(=pass_case)`, `no_tests = auto`, `report_skipped = default`, and `timeout_seconds = 0`. These five values are also declared attrs on `nextest_buck_artifact_junit` and are literal action inputs, so changing a result-affecting value changes the Buck action identity. Profiles must match `[A-Za-z0-9][A-Za-z0-9_-]*`; syntactically safe `default-*` names are accepted, but nextest owns that upstream namespace and may assign them special meaning. Filters remain one quoted nextest expression and are never placed in TOML or paths. A positive timeout generates only the bounded `slow-timeout` table; `report_skipped = ignored` adds the corresponding JUnit setting. The fixed declared output remains `junit.xml`, while the generated profile-specific report and all other scratch stay private to each invocation. The adapter validates XML only to reject a broken internal report; it copies the nextest bytes unchanged and does not add a summary protocol.

## Supported results

The bounded result contract follows nextest's process boundary:

The result combinations exercised by the test suite are:

- pass: `filter = test(=pass_case)`; returns `0`.
- failure: `filter = test(=fail_case)`; exports a `<failure>`, returns `100`.
- ignored: `filter = test(=ignored_case)`, `report_skipped = ignored`, `no_tests = pass`; exports `<skipped>`, returns `0`.
- filtered: `filter = test(=pass_case)`; other cases are absent, returns `0`.
- no-tests: `filter = test(=does_not_exist)`, `no_tests = fail`; returns `4`.
- timeout: `filter = test(=timeout_case)`, `timeout_seconds = 1`; nextest reports ordinary status `100` with a JUnit `<failure>`.

At the direct adapter layer, completed pass and test-failure runs require a valid caller-owned exported report. Other setup/metadata/unknown nonzero statuses retain their raw nextest status and export a report if one exists. A required post-dispatch verification/export failure returns adapter status `3` and prints the raw nextest status; pre-dispatch validation returns `2`. Human-readable nextest output remains diagnostic, not a protocol.

A completed timeout, if later observed, remains nextest's ordinary test-failure class and JUnit `<failure>`; this milestone defines no timeout-specific XML marker. Process interruption, abort, and cancellation have no stable adapter classification and remain deferred.

## Build and test

A consumer configures the toolchain with executable targets, for example:

```python
nextest_toolchain(
    name = "nextest",
    cargo = ":cargo-executable",
    python = ":python-executable",
    cargo_nextest = ":cargo-nextest-launcher",
)
```

Each target must expose `DefaultInfo` and `RunInfo`; `cargo_nextest` is a launcher target used with the fixed `nextest` subcommand. The repository's fixtures under `tools/` are local convenience targets only.

The fixed declared-output build surface runs the successful `pass_case` contract as a keyed, local-only Buck action:

```sh
buck2 build //:nextest_buck_artifact_junit --show-output
# buck-out/.../__nextest_buck_artifact_junit__/junit.xml
buck2 build //:nextest_buck_artifact_junit
```

The declared `junit.xml` is a successful-build artifact only: it is owned by Buck and is available to `$(location :nextest_buck_artifact_junit)` consumers only when the action succeeds. A failing nextest result (status `100`) fails the Buck action; failed declared outputs are not a supported `$(location)` or consumer path. Buck's ordinary failed-action output and logs are the supported build diagnostics. Identical declared inputs produce deterministic byte-identical output in the lifecycle checks. The installed Buck2 does not expose a stable repository contract used here to claim a local cache hit, so the cache check reports that execution-observability gap; `buck clean` policy is likewise not claimed beyond fresh-state rebuild coverage. The rule supports only the five bounded controls above, not arbitrary nextest TOML. Retries, groups, failed-output retrieval, persistent nextest rerun records, remote execution, `error_handler`, and cache upload remain non-goals. The adapter still supports a caller-supplied `--junit-report` destination and propagates the nextest failure status, but this slice does not provide outer `buck2 test` capture, display, or retrieval of that report. Use the existing `buck2 test` surface below for fresh execution and failure/flaky status behavior.

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

The pass test also proves manifest-driven cwd/environment, runtime staging, source denial/no nested build, executable digest equality, and once-only private-root cleanup. Destination tests prove pre-dispatch rejection, existing-file replacement, paths with spaces, byte-identical pass-through, and status-3 precedence for forced export failures after raw `0` and `100`.

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
