# Buck2/nextest artifact handoff

This repository proves a local Buck2-to-nextest artifact boundary. Buck2 builds a native Rust test executable and emits a strict serialized manifest. The Rust adapter stages only those declared inputs, synthesizes the documented Cargo/nextest metadata shape, runs the declared nextest launcher, and exports nextest's JUnit XML before removing its private root.

## Prerequisites

- Buck2 with the bundled prelude `rust_test` rule.
- Rust and Cargo.
- `cargo-nextest` 0.9.143, exposing metadata/remap, filterset, output, profile, and no-tests controls used here.

The adapter runtime is Rust-only and requires no Python, Cargo, source-tree helper, ambient PATH tool, or runtime network access. Consumers provide the cargo-nextest launcher as an executable Buck target exposing `RunInfo`; the launcher is invoked with the fixed `nextest` subcommand. The v1 `nextest_toolchain` contract also declares an ordered bundle of regular execution resources, normalized POSIX destinations, `sha256:<hex>:<size>` identities, typed literal/relative-path environment records, and an opaque non-empty `bundle_platform` identity. Every launcher support file, shared library, or other runtime file not supplied by `RunInfo` must be a bundle resource; the adapter does not infer or obtain ambient runtime files. Clean uncached Buck builds fetch the pinned Rust crates through Buck-owned checksum-verified HTTP archives; that build-time network requirement is separate from network-free adapter actions. Production actions are local-preferred (`prefer_local = True`) with cache upload disabled. Supported adapter hosts are Linux and macOS with native process groups; Windows is unsupported in this milestone.

## Canonical invocation

`buck-artifact` remains the only supported adapter mode. The first reusable Buck test surface is `nextest_buck_test`, backed by the pinned Buck2 `ExternalRunnerTestInfo` API:

```text
nextest_buck_test_binary (one declared executable + explicit regular-file closure)
  -> nextest_buck_test (one top-level Buck suite, one ExternalRunnerTestInfo command)
  -> future adapter/nextest dispatch
```

The current milestone validates this ownership boundary and generic metadata contract; the Rust schema-v2 contract executable deliberately emits `dispatch=deferred-nextest-suite` and never invokes cargo-nextest. Real generic nextest dispatch remains a later milestone.

`buck-artifact` is the only supported adapter mode:

required default CI coverage: just ci runs adapter_relocated_sanitized. repository-level check, not a nested sh_test. missing relocation prerequisites fail CI with diagnostics before Buck or adapter dispatch. The check rebuilds the four Buck outputs and hands them to the adapter from a relocated working directory. `just ci` incurs the check's additional Buck build/execution cost; `adapter.sh` product/runtime behavior is unchanged. The supported local host boundary is POSIX with the named relocation utilities, an ambient build-time `python3`, and the fixed `/usr/bin/python3` launcher interpreter. Process-group and live-remote checks remain explicitly opt-in capability gates.

```text
nextest_buck_artifact buck-artifact --build-mode \
  --artifact PATH --manifest PATH \
  --cargo-baseline PATH --binary-baseline PATH --tests-baseline PATH \
  --cargo-nextest-argv EXECUTABLE... --end-argv \
  --runtime-resource PATH --bundle-json JSON \
  --bundle-resources PATH... --end-bundle-resources \
  --junit-report PATH \
  [--profile NAME] [--filter EXPRESSION] \
  [--no-tests auto|pass|warn|fail] \
  [--report-skipped default|ignored] [--timeout-seconds N]
```

Every input and the report destination are validated before any nextest help probe or dispatch. The production interface is strict declared-input mode only: direct/ambient modes, `/tmp` fallback, recursive argv files, Python/Cargo validators, source-denial helpers, and PATH discovery are not supported. `BUCK_SCRATCH_PATH` is the only scratch parent; it must be a project-relative execution-owned path, and the runner creates one private child beneath it. Existing report parents must be real directories, not symlinks; the destination may be absent or an existing regular file, but may not be a directory or symlink. Export uses a mode-0600 same-directory temporary, fsync, and atomic replacement, so the last successful export wins. Linux and macOS use native process groups for cancellation and descendant cleanup.

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

A completed timeout, if later observed, remains nextest's ordinary test-failure class and JUnit `<failure>`; this milestone defines no timeout-specific XML marker. Process interruption uses the Unix signal-derived status for the first HUP/INT/TERM and drains the owned process group before scratch cleanup. Stable cross-platform cancellation compatibility remains deferred; Windows is unsupported.

## Build and test

A consumer configures the toolchain with executable targets, for example:

```python
nextest_toolchain(
    name = "nextest",
    cargo_nextest = ":cargo-nextest-launcher",
    bundle_resources = [":nextest-runtime-resource"],
    bundle_environment = [["NEXTest_RESOURCE", "relative_path", "runtime/resource.txt"]],
    bundle_platform = "linux-x86_64-fixture-v1",
)
```

Each launcher target must expose `DefaultInfo` and `RunInfo`; `cargo_nextest` is invoked directly with the fixed `nextest` subcommand. A consumer must attach at least one `nextest_bundle_resource` target to the toolchain; every required shared library, launcher support file, or other runtime file not already supplied by `RunInfo` must be declared this way. Resource `path` values are relative normalized POSIX paths and resource digests are provider-owned `sha256:<hex>:<size>` values checked before and after staging. Environment entries are ordered `[name, kind, value]` records where `kind` is `literal` or `relative_path`; names are unique and may not replace adapter-owned variables. `bundle_platform` is an opaque execution identity, not the test artifact target triple and not a host `uname` inference. Invalid versions, paths, digests, environment records, or platform identities fail before probing nextest. The repository's fixtures under `tools/` are local convenience targets only; shared libraries and interpreters are not automatically discovered.

The fixed declared-output build surface runs the successful `pass_case` contract as a keyed, local-preferred Buck action. Ordinary builds therefore remain backend-independent, while an explicitly configured Buck2 remote executor can select the same action with `--remote-only`:

```sh
buck2 build //:nextest_buck_artifact_junit --show-output
# buck-out/.../__nextest_buck_artifact_junit__/junit.xml
buck2 build //:nextest_buck_artifact_junit
# With caller-owned RE configuration:
buck2 --config-file "$BUCK2_NEXTEST_RE_CONFIG_FILE" build --remote-only //:nextest_buck_artifact_junit
```

The declared `junit.xml` is a successful-build artifact only: it is owned by Buck and is available to `$(location :nextest_buck_artifact_junit)` consumers only when the action succeeds. A failing nextest result (status `100`) fails the Buck action; failed declared outputs are not a supported `$(location)` or consumer path. Buck's ordinary failed-action output and logs are the supported build diagnostics. Identical declared inputs produce deterministic byte-identical output in the lifecycle checks. Buck2 action metadata is validated in-action for the declared adapter/tool/artifact paths. The relocated/sanitized scenario runs outside the repository with a sanitized PATH and Buck-owned scratch. A separate materialization check uses `buck2 log what-materialized` only when the installed Buck exposes stable parseable events; otherwise it reports an explicit observability gap. These checks do not claim cache hits, content-level inputs, or complete input enumeration. `buck clean` policy is likewise not claimed beyond fresh-state rebuild coverage. The rule supports only the five bounded controls above, not arbitrary nextest TOML. Cache upload remains disabled; retries, groups, failed-output retrieval, persistent nextest rerun records, `error_handler`, and cache validation remain deferred. The adapter supports a caller-supplied `--junit-report` destination and propagates the nextest failure status, but this slice does not provide outer `buck2 test` capture, display, or retrieval of that report. Use the existing `buck2 test` surface below for fresh execution and failure/flaky status behavior.

### Opt-in remote gate

`nextest_buck_artifact_remote.sh` is a repository-level, opt-in readiness gate, not a normal Buck test and not part of `just ci`. With no backend configuration it prints `remote-gate=blocked-no-backend` and exits 0 without invoking Buck. Configured mode requires both `BUCK2_NEXTEST_RE_CONFIG_FILE` (an existing regular caller-owned Buck2 config file) and `BUCK2_NEXTEST_RE_EXECUTION_PLATFORM_LABEL` (one exact caller-owned platform label); a label without a config, or a config without a label, is invalid and exits nonzero.

The supplied config must register/reference the caller's external cell and execution-platform target, set `[build] execution_platforms` to that target, and provide a supported `[buck2_re_client]` configuration. A config file cannot define the target inline, and this repository supplies no credentials, endpoint, vendor-specific properties, or execution platform. The gate preflights the resolved platform, then uses a unique isolation directory, `--remote-only`, `--no-remote-cache`, an event log, and pinned `what-ran`/`what-materialized` evidence. It passes only when exactly `root//:nextest_buck_artifact_junit` is observed/submitted with executor `RE`, the exact declared `junit.xml` is materialized, and its bytes contain `pass_case`. This is Buck-side remote-executor evidence; it does not attest worker-side execution or rule out RE-service deduplication. Unsupported Buck versions or unrecognized audit/log schemas report configured-mode `remote-gate=observability-gap` and exit nonzero; no configured-mode gap is a pass. Private logs/configuration diagnostics are never printed.

Run the credential-free control-flow assurance explicitly with `just nextest_buck_artifact_remote_selftest`. It substitutes a stub through `BUCK2`, verifies no-fallback, parsing, cleanup, signal, argument, and redaction behavior, and is never evidence of remote execution. The live gate can be run only when a supported backend and caller-owned platform are available, for example `BUCK2_NEXTEST_RE_CONFIG_FILE=/path/to/config BUCK2_NEXTEST_RE_EXECUTION_PLATFORM_LABEL=external//:remote-platform just nextest_buck_artifact_remote`. Cache hits/uploads, cancellation/descendant teardown, failed-output retrieval, per-test scheduling/delegation, and remote CI remain explicitly deferred until a real backend validates them.

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

This milestone does not add an adapter-owned XML/result schema, parse human output, use experimental libtest JSON, define an internal event protocol, or cover retries, generated outputs beyond the existing contract, direct nextest embedding, native provider promotion, or stable abort/cancel mapping. The existing action is local-preferred, with explicit `--remote-only` selection available only through caller-supplied supported RE configuration; no repository-owned executor, worker/delegation model, per-test remote scheduling, credentials, or mandatory remote CI is configured. The opt-in gate independently verifies remote placement and successful output materialization only when that backend exists; cache behavior, cancellation and descendant teardown, failed-output retrieval, and local/remote CI support remain deferred. Local tests and the self-test cannot claim those backend properties.
