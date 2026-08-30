# Buck2/nextest integration roadmap

## Current position

The repository proves two deliberately separate local surfaces. The build surface is a
Buck2-built artifact handoff. The production test surface is a fresh `buck2 test`
suite that runs the official, checksum-pinned cargo-nextest 0.9.143 launcher
selected by Buck for Linux x86_64/aarch64 and macOS x86_64/arm64. Required
`just ci` coverage runs both as repository-level checks, not nested `sh_test`s;
missing relocation, host, or process-inspection prerequisites fail with
diagnostics before dispatch. The production runner uses only declared inputs,
private scratch, and the opt-in v2 executor's declared JUnit directory. Its
additional Buck build/execution cost is intentional; `adapter.sh` and the
legacy declared-JUnit build action remain behaviorally separate.

```text
Buck2 rust_test
  -> declared version-1 manifest + Buck output
       -> POSIX adapter
            -> supplied Cargo/nextest metadata
                 -> cargo nextest list/run
                      -> nextest JUnit export
```

The adapter supports only the Buck artifact path. Its strict identity contains
`pass_case`, `fail_case`, ignored `ignored_case`, and non-ignored `timeout_case`; the separate two-case Cargo
fixture remains baseline observation/regeneration input only. Phase 4 staging,
rooted paths, runtime/cwd/environment, source denial, digest equality, synthetic
metadata, and once-only cleanup remain covered.

The additive test-coverage follow-up is tracked in
[`docs/test-coverage-follow-up.md`](test-coverage-follow-up.md). It preserves the
existing suite and adds observable checks for dispatch, configuration, validation,
report-export safety, and Buck toolchain behavior.

The schema-v2 production slice is implemented and its real declared-tool,
metadata, status, JUnit, and fresh-execution checks pass: the generic provider
contract supports one or more package-scoped binaries, including multiple
binaries per package and equal display names across distinct semantic IDs. The
Rust runner synthesizes the pinned 0.9.143 reuse-build metadata, validates real
`nextest list`, runs exactly one real `nextest run`, supervises its process group,
and publishes unchanged JUnit bytes into the executor-owned declared directory.
The bounded matrix covers pass (`0`), test failure (`100`), ignored/skipped,
filtered-out, explicit no-tests (`4`), and completed timeout behavior. The
opt-in executor preserves Buck status, diagnostics, and caller export; its
fresh-execution harness runs the real declared tool twice and rejects
cache/observability substitutions. The milestone remains open for outer
cancellation and descendant-teardown evidence: Buck may terminate the runner
before its signal handler runs, and nextest may create a separate process group.

A completed timeout remains an ordinary JUnit `<failure>`/test-failure status
with no distinct XML marker. Runner-side signal handling and cleanup cover only
signals delivered to the runner and process groups it can observe. The pinned
Buck executor may terminate the runner before that handler runs, and nextest
may create a separate process group, so outer cancellation and descendant
teardown remain deferred. Windows remains unsupported. The provider-derived runtime-file slice is now
proved for a generated Rust `resources` edge: `DistInfo.nondebug_runtime_files`
is authoritative, native executable-relative materialization is preserved, and
the no-resource control fails in the named test. Broader runtime semantics
(shared-library-specific proof, provider-derived environment/platform identity,
build-script outputs, and remote validation), plus retries/groups/capture and
compatibility simplification, remain future work.

The implemented schema-v2 `nextest_buck_test_binary`/`nextest_buck_test`
record-and-suite surface is the working production slice, not the selected
long-term consumer API. The selected, not-yet-implemented interface is one real,
queryable, provider-backed Buck test target over existing ordinary `rust_test`
targets:

```python
rust_test(name = "parser_tests", ...)
rust_test(name = "storage_tests", ...)

nextest_test(
    name = "tests",
    tests = ["//parser:tests", "//storage:tests"],
)
```

The normal invocation is `buck2 test //:tests`. Explicit `tests = [...]`
membership may cross package boundaries; one queryable suite target produces
one nextest invocation covering every selected binary. Buck analysis remains authoritative
for the executable, runtime closure, effective environment, and configured
artifact target/runner metadata through a narrow versioned Rust-test provider.
The rule derives owner, package, binary/display defaults, and a collision-free
synthetic CWD rather than asking consumers to repeat them or inferring them from
output paths or ambient state.

A declaration macro may later be optional sugar, but a macro-generated
`rust_test` plus suite is **not canonical**: it creates a second real test target
and risks duplicate broad-pattern execution and query noise. Automatic package
discovery is **rejected as primary**, as are one invocation per Rust binary and
BXL as the primary lifecycle. A global executor that transforms ordinary
`rust_test` specs is **rejected as primary** because it receives opaque execution
handles rather than analysis providers, would take on metadata aggregation and
result mapping, leaves runtime-closure semantics unresolved, and weakens the
version-pinned Execute2/remote story. Copying or forking the Rust prelude is not
a fallback.

Cargo-nextest 0.9.143 provides one inherited process environment and at most one
target platform per invocation. Selected targets must therefore have equal
provider-normalized effective environments, artifact runtime triples, and
compatible normalized runner requirements; analysis fails on disagreement
rather than merging, guessing, partitioning, or using the first record.
Validated suite additions apply uniformly after that check and cannot set
adapter/nextest-owned `CARGO_*`, `NEXTEST_*`, `LD_*`, or `DYLD_*` variables.
Rust artifact runtime triple/runner metadata, cargo-nextest `bundle_platform`
identity, and Buck execution/RE platform are three distinct concepts.

Stock `buck2 test //:tests` requires no custom executor: the runner writes JUnit
to Buck-owned private scratch, validates it, uses nextest status and diagnostics,
and removes the report during cleanup without promising caller-visible XML.
Caller-visible JUnit remains opt-in: when the pinned executor supplies its
declared-directory capability, the same runner also publishes the unchanged
validated XML through the existing secure path. The separate
`nextest_buck_artifact_junit` decision gate is unchanged. Eventual production
defaults are `filter = "all()"` and `no_tests = "fail"`; both are overridable,
behavior-affecting settings; current fixture defaults remain unchanged.

## Terminology correction

The planned result format is **JUnit XML**, not Javadoc XML.

- **Binary and runtime metadata** tells the adapter/nextest what to discover
  and how to launch it.
- **JUnit XML** reports test results to Buck2 or CI after execution.
- Javadoc XML is unrelated to this test-runner integration.

JUnit XML should be treated as a reporting surface, not as a replacement for
test discovery metadata or a process-execution protocol.

## Roadmap

### 0. Prove the primary Buck test executor and failed-output handoff

This prerequisite is complete for the pinned local Buck2 integration. The
project-owned executor is selected only with
`--config test.v2_test_executor=<absolute-executor-path>` and accepts the
pinned Buck commit `1560aca2002865cd73d7cafb22c705cfb640b2bc`. Buck still owns
every test command through `Execute2`, resource throttling, status, diagnostic
output, and cancellation. The executor preserves stock unordered processing,
requests a declared local `junit` directory only for specs whose exact type is
`nextest`, and exports unchanged `junit.xml` bytes to a fresh caller-owned
`--junit-dir`, including for ordinary failures and timeouts.

The caller directory is deliberately not a Buck output: it is a temporary
capability supplied by the invocation. The executor validates it outside the
repository and outside `buck-out`, traverses Buck output without following
symlinks, bounds and validates XML, and publishes with a 0600 temporary and
no-replace atomic commit. Invalid reports become per-target
`INFRA_FAILURE`; independently valid reports remain, while Buck's aggregate
nonzero status is authoritative. Cancellation and transport/reporting failure
close future publication rather than falling back to the stock executor.

The compiled fixtures prove protocol/output ownership, not nextest behavior:
fixture XML is not cargo-nextest output. The isolated package requires Rust
1.88+, uses vendored protocol bindings from the pinned Buck source, and is
kept out of the adapter dependency graph. The stock executor remains the
repository default, and the existing `nextest_buck_artifact_junit` build action
is unchanged pending its separate operator decision gate.

### 1. Capture the Cargo/nextest baseline

Before synthesizing anything, record what ordinary nextest consumes from a
representative Cargo project:

- Cargo package IDs, target kinds, and test binary IDs.
- Cargo metadata and build-summary information.
- Nextest binary-list information and the fields required for listing.
- Test-binary paths, working directories, and filter identities.
- Environment variables and dynamic-library search paths.
- Dependency artifacts and build-script outputs.
- Exit-code behavior, captured output, and JUnit output.

**Deliverable:** a small baseline fixture and a documented inventory of the
minimum data needed by nextest. Avoid reproducing Cargo data that nextest does
not consume.

### 2. Define Buck2's test-artifact contract

Determine what a Buck2 Rust test target must expose to an adapter. The contract
should include:

- The executable test artifact.
- Stable test identity, package identity, target kind, and binary ID.
- Project-relative or sandbox-valid paths.
- Working directory.
- Runtime dependencies, including shared libraries and data files.
- Environment variables and toolchain runtime paths.
- Build-script and generated-file outputs where applicable.
- Platform and target information.

Prefer a structured, versioned manifest or provider over parsing human-readable
Buck2 output. The manifest should be usable in a local sandbox and should not
contain host-only absolute paths unless Buck2 declares and materializes them.

**Deliverable:** a Buck2 provider or serialized artifact manifest with one
supported Rust test target and a clear compatibility/version policy.

### 3. Build a synthetic Cargo/nextest compatibility layer

Use the Buck2 artifact contract to create the smallest Cargo-shaped layout
nextest requires. This may include:

- A synthetic workspace or manifest.
- Package and target metadata.
- A nextest-compatible binary list.
- A compatible build-summary or equivalent metadata input.
- A target directory layout containing the Buck2-built test binary.
- Runtime dependency and environment setup.

The adapter should invoke nextest through documented CLI behavior where
possible. It should not depend on unstable internal `nextest-runner` events or
private `cargo-nextest` APIs as the first implementation.

**Deliverable:** `cargo nextest list` and `cargo nextest run` operate on a
Buck2-built test artifact without Cargo recompiling or rediscovering it.

The explicit `list` call is valuable during development because it validates the
translated metadata and test identities before execution. It is not yet a
commitment that every production run must perform a redundant `list` immediately
before `run`. A final Buck integration may expose listing through Buck's test
listing interface, retain it as a preflight/debug mode, or omit it from the
normal execution path once the metadata contract is independently tested.

### 4. Prove local artifact execution

Expand the current local spike from a Cargo-owned fixture to a Buck2-owned
artifact. Validate, in order:

1. Test listing exposes the expected Buck2-provided test identity.
2. The pass and intentional-failure cases execute the expected binary.
3. One declared static runtime data file is available.
4. The declared working directory and environment are correct.
5. Filters select the intended tests without relying on Cargo-only names.
6. Nextest exit codes propagate through the adapter.
7. Documented output controls make diagnostics deterministic.

**Deliverable:** a local end-to-end Buck2-built test target with pass, failure,
filter, runtime, cwd/environment, output, and status assertions. JUnit XML and
full status mapping are deferred to Phase 5.

### 5. Add result reporting and status mapping (bounded milestone complete)

Completed in the first bounded milestone:

- Preserve nextest's documented process exit semantics for success, test failure,
  and explicit no-tests selection.
- Pass through nextest JUnit bytes to a required caller-owned destination before
  private-root cleanup.
- Cover pass, failure, ignored/skipped, filtered-out, and no-tests behavior.
- Keep filtered-out tests absent from JUnit and human output diagnostic only.
- Avoid experimental libtest JSON, internal event recordings, adapter-owned
  summaries, and invented event streams.

The completed-timeout boundary is intentionally ordinary test failure/JUnit
`<failure>`; the deterministic `timeout_case` fixture and bounded profile
regression are now complete, and no timeout-specific marker is invented. Stable
interruption, abort, and cancellation mapping remains deferred because nextest 0.9.143 and
the current host do not provide the required stable machine-readable and
process-group test boundary.

**Bounded deliverable:** documented JUnit/status rules and fixture coverage for
pass, failure, ignored/skipped, filtered, no-tests-selected, and deterministic
completed-timeout behavior. Interruption/abort/cancel mapping remains explicitly
deferred pending a supported machine-readable/process-group contract and suitable
environment.

### 6. Define output and run-state ownership

Decide which files belong to the Buck test target and which files are only
execution state. A physical location under `buck-out` is not enough to make a
file a Buck output: the rule or action must declare the output and expose it
through the Buck test integration.

Use three deliberately separate categories:

- **Declared target outputs:** caller-visible JUnit XML and, if useful, logs,
  machine-readable results, or a run archive. A declared output directory may
  contain several such files, including files selected by a supported profile
  or filter configuration.
- **Persistent nextest records:** optional run history used by nextest reruns.
  These records track mutable run state and test-event history, so they need an
  explicit retention, workspace-identity, concurrency, and `buck clean` policy;
  they must not silently become ordinary cached build outputs.
- **Per-run scratch:** the synthesized Cargo workspace, temporary metadata,
  nextest target/run state, and intermediate report. This must be private and
  writable for each invocation. It may use a Buck-declared execution/output
  area when Buck can provide one safely; otherwise it may use a private
  temporary directory. It must never rely on arbitrary unmanaged writes across
  `buck-out`.

Make output identity match supported nextest settings. Profiles, filters,
retries, timeouts, and similar settings that affect results must be Buck rule
attributes or otherwise participate in the output/cache key. Arbitrary
execution-time arguments either need an isolated non-cached result area or must
be rejected; they must not silently share a target's output directory.

Keep JUnit and any other declared result artifacts separate from nextest's
persistent rerun store. Test concurrent runs, cache hits, cleanup, `buck
clean`, and remote-like execution before promising result persistence.

**Concrete Phase 6 slice:** the `//:nextest_buck_artifact_junit` custom rule declares and returns a fixed-name `junit.xml` under `buck-out`. Its five attrs are `profile = ci`, `filter = test(=pass_case)`, `no_tests = auto`, `report_skipped = default`, and `timeout_seconds = 0`; changing any result-affecting attr changes the literal action command inputs and therefore the action identity. Profile names are safe ASCII identifiers, filters are one argv value, and scratch is private and cleaned. The action is local-preferred with remote cache upload disabled; ordinary builds retain local behavior, while explicit `--remote-only` can select a caller-configured remote executor. Unchanged keys may reuse the output and `buck clean` removes it. The existing `buck2 test` surface remains caller-owned and fresh.

The strict failed-run semantics slice is complete: a deliberately failing `//:nextest_buck_artifact_junit_expected_failure` proves that nextest status `100` fails the declared Buck action, and a separate consumer build proves that failed declared `junit.xml` is not a supported `$(location)`/consumer path. The repository-level integration selects the invocation's event log or documented build-report action error, checks adapter private-root cleanup, and avoids asserting failed-output deletion. Buck's ordinary failed-action diagnostics remain the supported build diagnostics.

The Phase 6 portability/action-key slice is complete. Consumers provide Cargo, Python, and cargo-nextest as executable targets exposing `DefaultInfo` and `RunInfo`; cargo-nextest remains a launcher used with the fixed `nextest` subcommand, while Cargo is keyed for source-denial and is not dispatched by build mode. The next local-readiness slice adds the versioned provider-owned bundle: every extra runtime file is a direct execution dependency with a normalized destination and checked `sha256:<hex>:<size>` identity, plus typed relative environment metadata and an opaque execution-platform identity. The adapter stages only those resources below its private Buck scratch root and rejects undeclared ambient fallback before nextest probing. Checked-in v1/v2 fixtures expose distinct bundle identities while preserving selected-tool coverage. The relocated/sanitized scenario and runner-side process-group cleanup are local readiness checks. The outer-cancellation probe is fail-closed but is not a passing CI gate: Buck may terminate the runner before its handler runs, and nextest may leave a child in a separate process group. Materialization-event evidence remains best-effort and does not claim complete input enumeration or cache behavior. The action is local-preferred with cache upload disabled; explicit remote-only selection is available only through caller-supplied RE configuration. The opt-in remote gate preflights the caller-owned external execution platform and fails closed on missing or unstable evidence; its self-test is control-flow coverage only. No persistent worker, delegation, per-test remote scheduling, credentials, repository-owned platform, or mandatory remote CI is configured. Nested Buck invocation from `sh_test` remains avoided. Persistent records, failed-output retrieval, outer cancellation/descendant teardown, cache behavior, `error_handler`, retries, groups, arbitrary profile TOML, and actual backend validation remain deferred.

**Deliverable:** a documented ownership and lifecycle contract for results,
persistent rerun records, scratch files, output identity, caching, and remote
execution, with a Buck rule/provider shape that declares target-associated
outputs without treating the whole `buck-out` tree as writable scratch.

### 7. Exercise nextest features against Buck2 metadata

Once basic execution and output ownership are stable, validate features that
depend on runtime and identity metadata:

- Retries.
- Timeouts.
- Test groups and scheduling.
- Output capture modes.
- Target runners and platform selection.
- Build scripts and dynamic libraries.
- Cancellation and process-tree cleanup.

Each feature needs an explicit acceptance test. Do not assume Cargo behavior
continues to hold when artifacts and metadata come from Buck2.

### 8. Validate sandboxing and remote-like execution

Repeat the artifact/path experiment in a constrained sandbox:

- No undeclared source-tree access.
- No host-local Cargo target directory.
- No host-local toolchain or dynamic-library paths.
- All binaries, libraries, data, and metadata are declared inputs.
- Paths remain valid after materialization in a different execution root.
- Buck2 can observe, cancel, and clean up the adapter's descendants.

**Deliverable:** a remote-like local test that demonstrates the adapter uses only
Buck2-declared inputs and outputs, followed by the opt-in
`nextest_buck_artifact_remote` gate when a supported Buck2 RE environment is
supplied. The gate requires `BUCK2_NEXTEST_RE_CONFIG_FILE` and
`BUCK2_NEXTEST_RE_EXECUTION_PLATFORM_LABEL`, caller-owned external-cell/platform
configuration, `--remote-only`, `--no-remote-cache`, exact `what-ran` RE evidence,
and exact `junit.xml` materialization. This proves Buck-side remote-executor observation/submission, not worker-side execution or absence of RE-service deduplication. Missing configuration is
`blocked-no-backend` with exit 0; configured observability gaps and all other
configured failures are nonzero. The self-test validates only control flow and
never substitutes for a backend. Cache validation, cancellation/descendant
teardown, failed-output retrieval, per-test delegation, and remote CI remain
deferred.

**Follow-up: resolve Buck2 RE platform propagation.** The current Buck2/BuildBarn
smoke setup made a real remote Execute attempt, but the request arrived with an
empty RE platform even though the caller-owned execution platform declared
`OSFamily` and `container-image` properties. Determine whether the adapter needs
a repository-owned Buck2 configuration/platform change, a compatibility update
for the supported Buck2 version, or both. Do not add a worker for an empty
platform. The follow-up is complete only when a fresh, non-cache-hit Execute
request carries the declared properties, matches the registered worker, and the
existing remote gate then passes its exact RE and materialization checks.

### 9. Reassess the long-term integration surface

After the compatibility layer is proven, decide whether ordinary nextest CLI
is sufficient. Possible outcomes are:

- Keep the CLI adapter and stabilize the Buck2 metadata manifest.
- Add an explicit nextest-facing standalone binary/runtime manifest.
- Add a Buck2 delegation execution backend for remote execution and resource
  ownership.
- Reconsider direct embedding only if the required CLI boundary cannot express
  the integration; embedding carries substantial API and version risk.

The decision should be based on measured metadata and execution requirements,
not on the initial Cargo fixture.

## Remaining roadmap work

The schema-v2 production vertical slice above is the current-state record. The
following items remain ordered follow-ups; detailed rationale, boundaries, and
acceptance evidence live in [`docs/roadmap-follow-ups.md`](roadmap-follow-ups.md).

The per-test isolation-cleanup experiment is documented as deferred after a
failed cost/complexity tradeoff in
[`roadmap-follow-ups.md#per-test-isolation-cleanup`](roadmap-follow-ups.md#per-test-isolation-cleanup).
It is not implemented or part of the active sequence below; use the bounded
stale-isolation cleaner for session-level recovery.

1. **[Preserve the remote-expansion freeze](roadmap-follow-ups.md#freeze-remote-readiness).** Keep the fail-closed gate and blocker evidence without expanding the remote claim before the local consumer path is proved.
2. **[Establish the provider contract and selected public surface](roadmap-follow-ups.md#primary-buck-test-surface).** Pass `buck2_nextest_rust_provider_compatibility`, then define provider-backed `nextest_test(name, tests = [...])` over existing `rust_test` targets.
3. **[Prove the consumer surface](roadmap-follow-ups.md#consumer-surface).** Add the cross-package `buck2_nextest_consumer_surface` fixture and its environment, platform/runner, ambient-Cargo, identity, cardinality, defaults, and stock/opt-in report-mode checks.
4. **[Prove the real declared path](roadmap-follow-ups.md#real-declared-nextest).** Run the actual declared cargo-nextest toolchain through the selected production lifecycle without ambient fallback.
5. **[Prove the realistic runtime closure](roadmap-follow-ups.md#realistic-rust-runtime-closure).** Extend the completed resource proof through the selected provider to shared libraries, build-script outputs, effective environment, and artifact target/runner metadata.
6. **[Prove the core nextest value proposition](roadmap-follow-ups.md#core-nextest-value).** Cover retries, groups/concurrency, richer timeout/slowness and capture behavior, ignored-test parity, and realistic runtime dependencies through the production rule and real toolchain.
7. **[Retire obsolete compatibility surfaces](roadmap-follow-ups.md#simplify-compatibility).** Make the low-level record rule internal or remove it only after provider-backed behavioral replacements exist; then reassess unnecessary inputs, fault seams, and implementation-pinning tests.
8. **[Reassess the integration and resume remote validation](roadmap-follow-ups.md#reassess-and-resume-remote).** Decide whether the CLI/remap boundary is sufficient and then resume live platform propagation, materialization, failed-result, cache, and broader cancellation validation.

The consumer fixture depends on provider compatibility and realistic runtime
evidence; ergonomic syntax alone cannot advance production-readiness claims. The
existing declared-JUnit build action remains behind its separate,
evidence-backed operator decision gate. Direct nextest embedding or forking,
per-test Buck delegation, persistent workers/records, and richer event/result
protocols remain explicitly deferred until evidence requires them.
