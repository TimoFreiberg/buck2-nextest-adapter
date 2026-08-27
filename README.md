# Buck2/nextest artifact handoff

This repository proves a local Buck2-to-nextest boundary. Buck2 builds native Rust test executables and owns their runtime closure through the bundled prelude's `DistInfo.nondebug_runtime_files`; the Rust adapter runs each declared executable from Buck's native materialization, synthesizes the documented Cargo/nextest metadata shape, runs the declared nextest launcher, and exports nextest's JUnit XML before removing its private writable root.

## Prerequisites

- Buck2 with the bundled prelude `rust_test` rule.
- Rust and Cargo.
- The production `nextest_buck_test` rule selects an official, checksum-pinned
  cargo-nextest 0.9.143 archive declared by Buck: Linux x86_64/aarch64 or macOS
  x86_64/arm64 (using the universal macOS archive).
- The separate `nextest_buck_artifact_junit` build action accepts a consumer-
  declared cargo-nextest launcher and explicit runtime bundle.

The adapter runtime is Rust-only and requires no Python, Cargo, rustc, source-tree helper, ambient PATH tool, or runtime network access. The production launcher is selected from Buck toolchain inputs and is invoked with the fixed `nextest` subcommand. Launcher support files or runtime files not supplied by `RunInfo` must be explicitly declared as regular-file bundle resources; a self-contained launcher may declare no resources. The adapter does not infer or obtain ambient runtime files. Clean uncached Buck builds fetch pinned Rust crates and official nextest archives through Buck-owned checksum-verified HTTP archives; that build-time network requirement is separate from network-free runner actions. The production test rule is non-cacheable and local-preferred where Buck permits; its caller JUnit export requires the opt-in v2 executor. Supported runner hosts are Linux and macOS with native process groups; Windows is unsupported.

## Opt-in Buck test executor and JUnit export

The repository also contains an **opt-in** Buck v2 test executor for the pinned
Buck binary `buck2 2026-07-14-1560aca2002865cd73d7cafb22c705cfb640b2bc`.
The executor package is isolated from the adapter and requires Rust 1.88 or
newer. It preserves Buck's ownership of test execution: Buck sends each
`ExternalRunnerSpec`, the executor asks Buck's `TestOrchestrator.Execute2` to
run the command, and the executor reports the resulting status back to Buck.
It does not run test commands itself and it is not the repository default.

For a fresh run, create a private caller-owned directory whose only child is an
empty directory named `junit`, then pass that child to the executor:

```sh
case "$(uname -s)" in
  Darwin) temp_root=/private/tmp ;;
  Linux) temp_root=/tmp ;;
  *) echo "unsupported host" >&2; exit 2 ;;
esac
root=$(mktemp -d "$temp_root/buck2-nextest.XXXXXX")
mkdir "$root/junit"
set +e
buck2 --config test.v2_test_executor="$(buck2 build --show-output //:nextest_v2_executor | tail -1 | cut -d' ' -f2)" \
  test //your:nextest-target -- --junit-dir "$root/junit"
status=$?
set -e
# Upload "$root/junit" as diagnostics, then preserve "$status" as the CI result.
exit "$status"
```

The deterministic timeout form is `-- --timeout 1 --junit-dir "$root/junit"`.
The executor accepts Buck's pinned FD or loopback-address transport preamble,
consumes Buck's compatibility arguments, and never forwards `--timeout` or
`--junit-dir` to the test command. The destination must be an absolute,
fresh, empty `junit` directory outside the repository and outside every path
containing a `buck-out` component. The executor validates Buck's returned
local declared output without following symlinks, requires exactly one
`junit.xml`, bounds and validates the XML, and publishes unchanged bytes to a
0600 temporary followed by an atomic no-replace commit. It never writes into
the source tree or an unmanaged `buck-out` directory.

A passing test reports Buck `PASS` and publishes its report. A failing test or
Buck timeout reports `FAIL`/`TIMEOUT`, keeps the original Buck stdout/stderr
details, and still publishes a valid report. A missing, malformed, unsafe, or
unexportable report produces `INFRA_FAILURE` for that target and a nonzero Buck
aggregate result; a valid report from another target remains available. Buck's
exit status is authoritative, so CI must upload any files in the fresh
caller-owned directory without replacing the failed status. Cancellation or a
transport/reporting failure stops later publication; already committed reports
are retained and late temporary reports are not committed.

The executor remains a transport and output-ownership component: it does not run
nextest itself. The production Rust schema-v2 runner performs metadata synthesis,
real nextest discovery and execution, and unchanged JUnit publication before the
executor exports the declared report to the caller.

## Canonical invocation

`nextest_buck_test` is the supported fresh-test surface for the schema-v2
vertical slice, backed by the pinned Buck2 `ExternalRunnerTestInfo` API:

```text
nextest_buck_test_binary (one Rust executable exposing DistInfo)
  -> nextest_buck_test (one top-level Buck suite, one ExternalRunnerTestInfo command)
       -> nextest_buck_test Rust runner
            -> declared cargo-nextest 0.9.143 list/run
                 -> one unchanged JUnit report
```

Buck owns the enclosing command, executable/runtime materialization, resource
limits, status, diagnostics, cancellation, and declared JUnit directory. A Rust
executable's `DistInfo.nondebug_runtime_files` is the authoritative runtime-file
closure; consumers do not enumerate destinations. Declared executables and
provider runtime files are read-only inputs to the runner, while synthetic
Cargo/nextest metadata and other writable state stay under its private scratch
root. Suite environment and platform identity remain explicit in this slice.
Nextest owns test discovery, per-test process execution, scheduling, and JUnit
generation. The runner never invokes Cargo or rustc, enumerates individual tests,
parses human output, uses PATH or runtime network access, or consumes a
checked-in test-name list. It checks each scratch-parent component for symlinks before creating its
private child, but the portable path API cannot make validation and creation a
single dirfd-atomic operation; this remains a residual TOCTOU limitation, not a
race-free guarantee.

`buck-artifact` remains the separate build-action adapter mode:

`just ci` runs the relocated artifact check, the generated-resource runtime
closure check, the provider/action contract, the schema-v2 native-materialization
relocation check, and the real declared nextest production check as repository-level
checks, not nested `sh_test`s. Missing
relocation or host/process-inspection prerequisites fail CI with diagnostics
before Buck or adapter dispatch. The supported production test hosts are Linux
x86_64/aarch64 and macOS x86_64/arm64; the macOS tool is the universal archive.
Process-group and live-remote checks remain bounded by their documented
host/backend requirements.

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

Every input and the report destination are validated before any nextest help probe or dispatch. The production interface is strict declared-input mode only: direct/ambient modes, `/tmp` fallback, recursive argv files, Python/Cargo validators, source-denial helpers, and PATH discovery are not supported. `BUCK_SCRATCH_PATH` is the only scratch parent; it must be a project-relative execution-owned path, and the runner creates one private child beneath it. Existing report parents must be real directories, not symlinks; the destination may be absent or an existing regular file, but may not be a directory or symlink. Export uses a mode-0600 same-directory temporary, fsync, and atomic replacement, so the last successful export wins. If the runner receives a termination signal, Linux and macOS use native process groups for the groups the runner can observe. Outer Buck cancellation may terminate the runner before it receives that signal, and nextest may create a separate group; complete descendant cleanup is not yet guaranteed.

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

A completed timeout, if later observed, remains nextest's ordinary test-failure class and JUnit `<failure>`; this milestone defines no timeout-specific XML marker. If the runner receives HUP, INT, or TERM, it returns the corresponding Unix signal-derived status and drains the process groups it can observe before scratch cleanup. The pinned Buck executor can terminate the runner action before the runner receives a signal, and nextest may create a separate process group, so outer cancellation and descendant teardown remain unproven and deferred. Windows is unsupported.

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

Each launcher target must expose `DefaultInfo` and `RunInfo`; `cargo_nextest` is invoked directly with the fixed `nextest` subcommand. Bundle resources are optional: a self-contained launcher may use an empty list. Every required shared library, launcher support file, or other runtime file not already supplied by `RunInfo` must be declared as a `nextest_bundle_resource`. Resource `path` values are relative normalized POSIX paths and resource digests are provider-owned `sha256:<hex>:<size>` values checked before and after staging. Environment entries are ordered `[name, kind, value]` records where `kind` is `literal` or `relative_path`; names are unique and may not replace adapter-owned variables. `bundle_platform` is an opaque execution identity, not the test artifact target triple and not a host `uname` inference. Invalid versions, paths, digests, environment records, or platform identities fail before probing nextest. The repository's fixtures under `tools/` are local convenience targets only; shared libraries and interpreters are not automatically discovered.

The fixed declared-output build surface runs the successful `pass_case` contract as a keyed, local-preferred Buck action with cache upload disabled. Ordinary builds therefore remain backend-independent, while an explicitly configured Buck2 remote executor can select the same action with `--remote-only`:

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

The pass test also proves manifest-driven cwd/environment, source denial/no nested build, executable digest equality, and once-only private-root cleanup. The production `buck2_nextest_runtime_closure` check additionally proves that a Buck-generated Rust resource attached through `resources` is available through `DistInfo.nondebug_runtime_files`, while an otherwise identical target without that edge fails in the named testcase and publishes a normal JUnit failure. Destination tests prove pre-dispatch rejection, existing-file replacement, paths with spaces, byte-identical pass-through, and status-3 precedence for forced export failures after raw `0` and `100`.

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
