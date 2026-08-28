# Roadmap follow-ups

This document expands the short, not-yet-implemented follow-ups in
[`nextest-buck2-roadmap.md`](nextest-buck2-roadmap.md). It records the approved
order and acceptance boundaries without selecting speculative Buck2 provider
field names, encoding syntax, or Rust crate APIs.

## Architectural invariants

These constraints apply to every follow-up:

- Buck remains authoritative for build artifacts, runtime closure, execution
  inputs, outputs, and global resource ownership.
- Nextest remains authoritative for test discovery within declared binaries,
  per-test process spawning, retry, timeout/slowness, grouping and scheduling
  intent, output capture, and JUnit generation unless evidence forces a
  narrower integration.
- The adapter or runner must not invoke Cargo or rustc to compile or rediscover
  Buck artifacts.
- No source-tree or arbitrary unmanaged `buck-out` writes are allowed. Use
  Buck-declared locations and private scratch; `/tmp` is allowed only for a
  bounded direct fallback.
- Result-affecting configuration must participate in Buck identity wherever
  outputs are cacheable. Fresh test execution must use Buck's test lifecycle,
  not rely on an ordinary build cache.
- Preserve exact nextest JUnit bytes and documented process statuses. Do not
  parse human output or invent an unstable event or result protocol.
- Process-tree cleanup, cancellation, and no-orphan behavior are load-bearing
  before remote support can be claimed.
- Consumer setup should become simpler even when that requires somewhat more
  complexity inside this project.

Current implementation evidence includes the build-output rule in
`nextest.bzl:206-272`, the Rust dispatch/lifecycle implementation in
`adapter/src/bin/nextest_buck_artifact.rs`, shared schema/staging logic in
`adapter/src/manifest_v1.rs` and `adapter/src/manifest_v2.rs`, the recorder
fixture in `tools/nextest_cargo_nextest_v1.py:28-56`, and the roadmap state in
`docs/nextest-buck2-roadmap.md`.

<a id="per-test-isolation-cleanup"></a>
## Immediate maintenance: clean disposable Buck isolations after each test

**Purpose and evidence.** Repository tests create uniquely named Buck
isolations, and those outputs accumulate even though most scenarios will never
reuse them. The bounded stale-isolation cleaner remains necessary recovery for
interrupted, crashed, or legacy runs, but it should not be the normal lifecycle.

**Desired end state.** Every test helper that owns a disposable isolation invokes
Buck's `clean` for that isolation after its Buck children have exited. A failure
keeps diagnostics in its private temporary directory while still releasing the
Buck isolation. A scenario that intentionally reuses an isolation cleans it only
after its final cache assertion.

**Implementation boundaries.** Use `buck2 --isolation-dir <name> clean`; never
remove Buck output with `rm -rf`. Keep cleanup inside a trap/finalizer that runs
after child quiescence, preserve `v2` and caller-shared isolations, and retain the
bounded stale-cleanup command for abandoned directories.

**Acceptance evidence.** The relevant test helpers leave no disposable custom
isolation after successful and expected-failure runs, cache-reuse scenarios
clean only after their final assertion, and the existing stale-cleanup contract
continues to cover interrupted or legacy output.

<a id="freeze-remote-readiness"></a>
## 1. Freeze further remote-readiness expansion temporarily

**Purpose and evidence.** Phase 8 has a fail-closed remote gate and records the
live platform-propagation blocker, while Phase 7's user-visible nextest value is
still unproven. More action observability would not close the local production
path gaps shown by the current evidence above.

**Desired end state.** Preserve the existing gate and blocker record, but spend
no further implementation effort on RE observability until the production Buck
test rule, real declared nextest path, and realistic runtime closure pass.

**Implementation boundaries.** This is a prioritization boundary, not removal
or completion of Phase 8. Do not weaken fail-closed behavior, claim worker-side
execution, or add a worker for an empty RE platform.

**Dependencies/order.** Resume remote work only after the provider gate,
consumer surface, real declared path, realistic closure, and core nextest checks
have produced their acceptance evidence.

**Acceptance evidence.** Existing remote control-flow checks remain registered.
The later live gate is
`buck2_nextest_remote_platform_and_materialization`, using the production Buck
test rule and real declared nextest toolchain; it must independently fail when
declared platform properties do not reach a fresh Execute request or when exact
result materialization is absent.

**Risks/decision triggers.** A supported backend and fresh Buck2 platform/API
research are required before interpreting the platform-propagation failure.

<a id="primary-buck-test-surface"></a>
## 2. Define the primary Buck test surface

### Completed prerequisite: pinned opt-in executor handoff

Before implementing the generic Rust runner, this repository now proves the
primary `buck2 test` transport and failed-report boundary with the project-owned
executor in `executor/`. It is selected only through
`test.v2_test_executor=<absolute path>` and is pinned to Buck commit
`1560aca2002865cd73d7cafb22c705cfb640b2bc`. Buck remains responsible for every
command, resource decision, status, diagnostic stream, and cancellation through
`Execute2`; the executor preserves stock unordered request processing and
reports `EndOfTestResults` rather than replacing Buck's verdict.

For exact `nextest` specs, the executor requests one non-remote declared
`junit` directory, injects `BUCK2_NEXTEST_JUNIT_DIR`, validates Buck's returned
local directory and unchanged XML, and securely exports it to a fresh,
caller-owned directory supplied after `--`. The caller directory is outside
the repository and unmanaged `buck-out`, and publication is bounded,
symlink-resistant, mode `0600`, atomic, and no-replace. Test failures and
timeouts retain valid reports while keeping Buck nonzero; malformed or missing
reports become `INFRA_FAILURE`, and independently valid partial reports remain.
A cancellation or transport/reporting failure closes future publication without
falling back to the stock executor.

This is a transport/output proof using compiled fixture XML, not proof of
cargo-nextest execution. The stock executor remains the default, the existing
`nextest_buck_artifact_junit` build action remains unchanged behind its separate
operator decision gate, and the isolated executor requires Rust 1.88+. The
following generic runner work must consume this boundary rather than move test
process ownership out of Buck.

**Purpose and evidence.** `nextest.bzl:26-77` currently exposes a declared JUnit
build action, while fresh test execution belongs to Buck's test lifecycle. The
implemented `nextest_buck_test_binary` records plus `nextest_buck_test` suite are
the working production slice, not the selected consumer API. The current action
is documented history and must not be silently removed or promoted by this
roadmap update.

**Desired end state.** The selected public rule is a real, queryable Buck test
target over explicit dependencies on existing ordinary `rust_test` targets from the bundled prelude:

```python
rust_test(name = "parser_tests", ...)
rust_test(name = "storage_tests", ...)

nextest_test(
    name = "suite",
    tests = ["//parser:tests", "//storage:tests"],
)
```

`tests = [...]` supports cross-package membership. `buck2 test //:suite` runs one
suite target and one nextest invocation covering all selected binaries through
the normal Buck test lifecycle. Users do not author adapter record targets.
Production-facing defaults are eventually `filter = "all()"` and
`no_tests = "fail"`; both are explicit, overridable, behavior-affecting settings.
Caller-visible JUnit remains opt-in. This is future behavior: current fixture defaults remain unchanged.

**Implementation boundaries.** A declaration macro may later add optional sugar,
but a macro-generated `rust_test` plus suite is **not canonical** because the
Rust test remains a second real Buck test target, introducing duplicate execution
under broad target patterns and query noise. Automatic package scanning is **rejected as primary**; membership stays explicit.
A global custom executor that transforms ordinary `rust_test` specs is **rejected as primary**: the pinned
executor receives opaque execution handles rather than analysis providers,
would expand into metadata/aggregation and result-mapping ownership, has
unresolved runtime-closure semantics, and weakens the current remote/Execute2
placement story. BXL as primary lifecycle and one nextest invocation per binary
are also rejected. Reopening any of these architectures requires new evidence
and operator approval.

Stock `buck2 test //:suite` must work without the custom executor. The runner
creates JUnit in Buck-owned private scratch, validates it, determines success or
failure from nextest status, preserves diagnostics, and removes the report during
cleanup; it promises no caller-visible XML. Caller-visible JUnit is separately
opt-in: when the pinned executor provides its declared-directory capability, the
same runner publishes the same unchanged validated XML through the existing
secure export path.

This change neither removes nor promotes the existing declared JUnit build
action. Before either surface changes, an operator-approved decision record must
name the owner/approver, selected outcome, passing evidence,
migration/documentation consequences, and explicit removal or support boundary.
The selected outcome must be one of: classify and remove the old action as
temporary, retain it as a separately documented optional reporting API, or keep
it supported. The evidence must cover the real toolchain, documented statuses,
unchanged JUnit bytes and diagnostics, cancellation, and fresh-execution
lifecycle. No implementation may remove, promote, or leave both surfaces
indefinitely ambiguous before that record exists.

**Dependencies/order.** Pass the provider compatibility gate in follow-up 3
before implementing `nextest_test`; then prove its consumer surface before
rewriting or retiring the working record-based path. The selected rule is
required by all later acceptance tests.

**Acceptance evidence.** The future `buck2_nextest_consumer_surface` family in
follow-up 4 proves queryability, cross-package aggregation, and ordinary stock
`buck2 test`; `buck2_nextest_real_declared_toolchain` proves the real declared
nextest path. Additional lifecycle assertions prove repeated execution is not
satisfied by a normal build cache, statuses remain documented, diagnostics
remain Buck-owned, and exact JUnit bytes are unchanged. The explicit
`buck2_nextest_cancellation_cleanup` probe remains fail-closed until the
Buck-to-runner-to-nextest boundary proves cancellation and descendant quiescence.

**Risks/decision triggers.** Buck2 test-provider APIs require fresh research.
The existing declared-JUnit operator decision gate remains mandatory and
independent of the selected consumer API.

<a id="generic-artifact-runtime-contract"></a>
## 3. Generalize the artifact/runtime contract

**Purpose and evidence.** `adapter/src/manifest_v1.rs` and the Rust runner encode
validated metadata and declared staging, while the current production slice
extracts only part of the bundled prelude's Rust runtime information. The
selected consumer rule requires a narrow, versioned Rust-test provider or a
supported additive prelude hook on ordinary `rust_test` targets.

**Provider compatibility gate.** Before any `nextest_test` implementation,
`buck2_nextest_rust_provider_compatibility` must publish both (1) a compatibility
matrix naming the supported Buck and bundled-prelude version and provider policy,
and (2) an executable proof that an ordinary prelude `rust_test` exposes the
required provider without creating a second real test target. If fresh
investigation finds only a copied/forked prelude, a macro-generated duplicate
test, or behavior loss, implementation stops and returns to the operator; it may
not choose among those architectures by momentum.

**Desired end state.** Provider-owned semantics are exactly one executable
association, Buck-authoritative runtime closure, normalized effective test
`env`/`run_env`, and artifact runtime triple/target-runner metadata needed by
nextest. Rule-derived semantics are the configuration-independent canonical
Buck owner label in cell/package/target form, package identity, deterministic
binary and Cargo package identities, non-unique display defaults, and root-safe,
collision-free synthetic package CWDs. Consumers repeat none of these fields.

The uniqueness key remains exactly `(package identity, canonical Buck target
label, binary identity)`. Cargo package IDs and nextest binary IDs are generated
deterministically and reversibly from that semantic triple. Filters map through
those generated identities plus test names discovered by nextest. Display name,
executable basename, staged filesystem path, and synthetic CWD are not identity.

**Environment compatibility.** Cargo-nextest 0.9.143 has one inherited process
environment. Every selected target's effective map must be equal after provider
normalization and path handling. Unequal maps fail analysis with conflicting
labels and keys; they are never ignored, partitioned, guessed, silently
represented by the first record, or replaced by suite values. Validated
suite-level additions merge only after compatibility checking, apply uniformly,
and may not set adapter/nextest-owned `CARGO_*`, `NEXTEST_*`, `LD_*`, or
`DYLD_*` variables.

**Platform compatibility.** Every selected executable must expose the same Rust
artifact runtime triple and provider-normalized runner requirement. A runner
requirement is either direct execution or a declared record containing executable
identity, argv, declared environment/input closure, and supported artifact triple.
Direct-versus-runner; different executable, argv, environment, or closure; or a
runner that does not support the common triple is incompatible. Distinct triples
or incompatible runners fail analysis before dispatch; schema validation also
rejects heterogeneous serialized platform/runner records. Rust artifact runtime
triple/runner metadata, cargo-nextest launcher `bundle_platform`, and Buck
execution/RE platform are distinct and are not compared as artifact triples.

**Implementation boundaries.** Reject missing fields, duplicate triples,
duplicate executable association, multiple-executable record, and
normalization/encoding collision before staging. In particular, reject one
executable associated with multiple records and multiple executables in one
record. Nextest `list` output is the sole source of test-case names for execution;
do not consume checked-in or build-time test-name lists absent a separately
approved Buck listing design. Only exact supported-provider field names and
collision-free encoding mechanics are deferred; they may not change semantic
identity. Never scan `buck-out`, infer closure from output layout, copy/fork the
Rust prelude to avoid provider research, or use ambient repository/home Cargo
configuration. Upward and home Cargo discovery must be neutralized; environment
and `[target.<triple>.runner]` behavior comes only from declared
provider/toolchain/suite inputs.

**Dependencies/order.** Pass the compatibility gate before implementing the
consumer fixture or runner changes. The real declared path and realistic closure
must then prove the selected provider semantics before production-readiness
claims.

**Acceptance evidence.** In addition to the compatibility gate,
`buck2_nextest_generic_multi_binary` covers same display names across targets and
multiple binaries owned by one target without ambiguous dispatch or duplicated
test-name metadata. Separate checks reject every invalid record form, colliding
identity, unequal environment, heterogeneous artifact triple, and incompatible
runner requirement.

**Risks/decision triggers.** Fresh supported-prelude research determines exact
provider fields and whether a stable additive hook exists. Absence of such a hook
is a consequential blocker requiring operator review, not permission to narrow
behavior or fork the prelude. Encoding syntax needs collision analysis.

<a id="consumer-surface"></a>
## 4. Implement and prove the selected consumer surface

**Purpose and evidence.** Consumer ergonomics is an early product contract, not
late cleanup. `buck2_nextest_consumer_surface` is a named future executable check
family; this roadmap smoke test verifies only that the requirement remains
specified and does not supply its runtime coverage.

**Fixture topology.** At least two package BUCK files declare ordinary prelude
`rust_test` targets, and exactly one public cross-package `nextest_test` suite
selects them. A repository-level harness runs Buck query/analysis and
`buck2 test //:suite`, and observes runner command cardinality without source
grep.

**Positive acceptance.** The check fails if consumers must author adapter record
targets or repeat package identity, owner label, binary identity, display name,
synthetic CWD, runtime destinations, effective environment, or platform metadata.
It proves one queryable suite and one nextest invocation cover all selected
binaries; broad target queries reveal no macro-generated duplicate Rust test
target; deterministic identities remain collision-safe; and provider-derived
runtime/environment reaches the tests. It covers eventual defaults
`filter = "all()"` and `no_tests = "fail"` plus explicit overrides, without
changing current fixture defaults.

**Negative and platform acceptance.** Distinct future analysis checks reject
unequal target effective environments, heterogeneous artifact runtime triples,
and incompatible runner requirements, including different runner executable or
argv and direct-versus-runner. Contract-level validation rejects heterogeneous
serialized platform/runner records. Positive equal-platform and equal-runner
cases pass independently of cargo-nextest bundle identity and Buck RE platform
selection.

`buck2_nextest_ambient_cargo_config_denied` uses an isolated harness with
conflicting ancestor and synthetic-HOME Cargo configuration, including poisoned
`[env]` and `[target.<triple>.runner]` entries. It proves only declared
provider/toolchain/suite metadata determines execution and never reads or
modifies the operator's real home.

**Report modes.** A stock-mode check runs `buck2 test //:suite` without an
executor report capability: the runner creates JUnit in Buck-owned private
scratch, succeeds or fails from nextest status, validates and removes the report,
and promises no caller-visible XML. A separate opt-in check supplies the pinned
executor's declared-directory capability and proves the same runner publishes
the same unchanged validated XML through the secure export path.

**Dependencies/order.** Requires `buck2_nextest_rust_provider_compatibility`.
Realistic runtime closure and core nextest feature checks remain prerequisites
for production readiness; ergonomic syntax alone is not parity evidence.

**Risks/decision triggers.** The fixture must observe Buck behavior rather than
pin generated source or internal target names. Any need for duplicate tests,
prelude forking, automatic discovery, or metadata repetition returns to the
operator.

<a id="rust-runner"></a>
## 5. Implement a Rust runner

**Purpose and evidence.** `adapter/src/bin/nextest_buck_artifact.rs` owns the
strict declared-input dispatch and supervision boundary. Rewriting
before interfaces settle would preserve accidental compatibility branches.

**Desired end state.** A small compiled runner parses and validates the declared
contract, stages it, constructs argv without shell interpolation, supervises only
the top-level nextest child/process group, propagates cancellation and cleanup,
and atomically copies unchanged JUnit bytes. Keep a launcher only where Buck
requires one.

**Implementation boundaries.** The runner must not enumerate or spawn individual
test cases, implement retry/timeout/group scheduling, parse human output, rewrite
JUnit, or synthesize an event/result protocol. It must not retain compatibility-
only shell branches without a current use case and must not invoke Cargo or
rustc.

**Dependencies/order.** Begin only after the selected Buck surface, provider
contract, and consumer acceptance shape are settled. Preserve existing
status/JUnit behavior while replacing the implementation.

**Acceptance evidence.** Existing status, exact-JUnit, malformed-input,
relocation, source-denial, and action-policy checks remain behavioral gates.
`buck2_nextest_cancellation_cleanup` remains an explicit fail-closed probe; it
becomes passing evidence only after the production Buck test rule and real
declared nextest toolchain provide a controllable boundary that proves signal
propagation and descendant quiescence.

**Risks/decision triggers.** Exact crate layout and libraries are deferred to
implementation research. Evidence, not backwards compatibility, determines
which shell seams survive.

<a id="real-declared-nextest"></a>
## 6. Prove real nextest through the declared production path

**Purpose and evidence.** The declared build/toolchain path uses the recorder in
`tools/nextest_cargo_nextest_v1.py:28-56`; the Rust runner now drives that same
strict launcher contract with sanitized environment and Buck scratch.

**Desired end state.** Run an actual Buck-declared cargo-nextest executable with
the complete closure of the currently declared fixture/toolchain inputs, a
sanitized environment, Buck-owned scratch, synthetic metadata, a Buck-built
artifact, real `list` and `run`, and byte-for-byte unchanged JUnit.

**Implementation boundaries.** Prove there is no ambient executable,
interpreter, library, or support-file fallback. This milestone closes the current
fixture/toolchain split but does not claim the provider-derived realistic Rust
closure in follow-up 7.

**Dependencies/order.** Requires the production test surface and generic
contract. It precedes realistic closure and all renewed RE work.

**Acceptance evidence.** `buck2_nextest_real_declared_toolchain`, using the
production Buck test rule and real declared nextest toolchain, must fail if list
or run is stubbed, any undeclared host tool/support file is used, scratch escapes
Buck ownership, or JUnit bytes change.

**Risks/decision triggers.** Toolchain packaging may require current nextest and
Buck executable-provider research, but cannot relax the ambient-input boundary.

<a id="realistic-rust-runtime-closure"></a>
## 7. Support a realistic Buck Rust runtime closure

**Purpose and evidence.** This increment closes the first provider-runtime
slice: the production `nextest_buck_test` path consumes the Rust executable's
`DistInfo.nondebug_runtime_files`, and a generated Rust `resources` edge is
available at the executable-relative native path. The positive production
scenario passes through real cargo-nextest; the otherwise identical no-resource
scenario reaches the named test and publishes its stable missing-resource
failure. Shared libraries, build-script outputs, provider-derived environment
and platform/runner metadata, and broader transitive semantics remain unproved.

**Desired end state.** Extend the selected narrow, versioned Rust-test provider
authority to shared libraries, generated/build-script outputs, runtime data,
effective environment, artifact runtime triple/runner requirements, and other
transitive runtime artifacts without consumer-authored layout or ambient
fallback.

**Implementation boundaries.** Never guess output layout, scan `buck-out`, use
ambient state, or repeat provider-derived fields in the suite declaration. Buck
remains authoritative for the complete closure. Neutralize ancestor and home
Cargo configuration, including `[env]` and `[target.<triple>.runner]`; target
runner support can enter only through the selected provider contract. Do not
copy or fork the prelude merely to avoid provider research.

**Dependencies/order.** Requires the provider compatibility gate, selected
consumer surface, and real declared toolchain proof. Provider/runtime evidence is
a prerequisite for the consumer interface to become production-ready.

**Acceptance evidence.** The completed `buck2_nextest_runtime_closure`, using
the production Buck test rule and real declared nextest toolchain, proves a
Buck-generated Rust `resources` dependency and fails when that specific provider
edge is removed. The registered provider/action contract additionally proves the
positive `DistInfo` closure is materialized without a packaging or staging action.
This closes only the generated-resource/provider-file portion; future extension
must independently prove shared-library or build-script behavior and the
provider-derived environment/platform semantics specified by
`buck2_nextest_consumer_surface` and
`buck2_nextest_ambient_cargo_config_denied` before this follow-up is complete.

**Risks/decision triggers.** If the supported bundled prelude cannot expose the
required closure through its proven provider/additive hook, stop and return to
the operator rather than choosing a fork, duplicate test, or behavior loss.

<a id="core-nextest-value"></a>
## 8. Prove the core nextest value proposition

**Purpose and evidence.** The roadmap feature list has no production-path proof
for all behaviors that justify nextest: process isolation, retry, timeout,
slowness, capture, ignored tests, and group concurrency.

**Desired end state.** End-to-end tests demonstrate those behaviors and a
realistic runtime dependency through the exact production rule and toolchain,
without moving per-test scheduling into Buck or the runner.

**Implementation boundaries.** Nextest owns discovery, per-test processes,
retry, timeout/slowness, grouping/scheduling intent, capture, and JUnit. Buck
owns global resources and the enclosing action. Combined scenarios are allowed,
but every behavior needs an independently failing assertion.

**Dependencies/order.** Requires the selected consumer surface, provider gate,
real declared path, and realistic runtime closure. It precedes claims of
production usefulness and resumed remote validation.

**Acceptance evidence.** The feature-to-test matrix below is authoritative for
future product coverage.

### Feature-to-test matrix

Every row uses the production Buck test rule and real declared nextest toolchain.
A shared check name never permits a shared, non-specific assertion.

| Feature | Named future check | Regression-sensitive assertion | Production-path constraint |
|---|---|---|---|
| Provider/prelude compatibility | `buck2_nextest_rust_provider_compatibility` | Fails unless the supported Buck/prelude matrix and ordinary-`rust_test` provider proof both pass without a duplicate test target. | Uses the production Buck test rule and real declared nextest toolchain. |
| Selected cross-package consumer surface | `buck2_nextest_consumer_surface` | Fails unless one queryable suite produces one nextest invocation without consumer-authored records or metadata repetition. | Uses the production Buck test rule and real declared nextest toolchain. |
| Ambient Cargo configuration denial | `buck2_nextest_ambient_cargo_config_denied` | Fails unless poisoned ancestor and synthetic-HOME environment/runner settings are ignored in favor of declared metadata. | Uses the production Buck test rule and real declared nextest toolchain. |
| Effective-environment compatibility | `buck2_nextest_environment_compatibility` | Fails unless equal normalized maps pass and unequal maps fail analysis with conflicting labels and keys. | Uses the production Buck test rule and real declared nextest toolchain. |
| Artifact-platform compatibility | `buck2_nextest_artifact_platform_compatibility` | Fails unless equal triples pass and heterogeneous triples fail analysis independently of bundle and RE platforms. | Uses the production Buck test rule and real declared nextest toolchain. |
| Target-runner compatibility | `buck2_nextest_target_runner_compatibility` | Fails unless equal runners pass and different executable/argv or direct-versus-runner requirements fail analysis. | Uses the production Buck test rule and real declared nextest toolchain. |
| Stock report mode | `buck2_nextest_stock_report_mode` | Fails unless private JUnit is validated and removed with no caller-visible XML while status and diagnostics remain correct. | Uses the production Buck test rule and real declared nextest toolchain. |
| Opt-in report mode | `buck2_nextest_opt_in_report_mode` | Fails unless the pinned capability publishes the same unchanged validated XML through the secure path. | Uses the production Buck test rule and real declared nextest toolchain. |
| Real declared list/run and unchanged JUnit | `buck2_nextest_real_declared_toolchain` | Fails if either invocation is stubbed, an ambient fallback is used, or exported JUnit differs byte-for-byte. | Uses the production Buck test rule and real declared nextest toolchain. |
| Generic multiple binaries and identities | `buck2_nextest_generic_multi_binary` | Fails on ambiguous dispatch, duplicate test-name metadata, same-display-name aliasing, or multiple binaries from one owner collapsing identity. | Uses the production Buck test rule and real declared nextest toolchain. |
| Realistic runtime dependency | `buck2_nextest_runtime_closure` | Fails when the independently declared shared-library or generated/build-script edge is omitted. | Uses the production Buck test rule and real declared nextest toolchain. |
| Multiple test processes and isolation | `buck2_nextest_retry_and_process_isolation` | Fails unless distinct test PIDs and isolated per-test state are observed. | Uses the production Buck test rule and real declared nextest toolchain. |
| Deterministic flaky retry | `buck2_nextest_retry_and_process_isolation` | Fails unless the designated flaky case records the configured attempt sequence and eventual result. | Uses the production Buck test rule and real declared nextest toolchain. |
| Timeout | `buck2_nextest_timeout_and_slowness` | Fails unless the over-limit case is terminated and reported with nextest's expected timeout result. | Uses the production Buck test rule and real declared nextest toolchain. |
| Slowness classification | `buck2_nextest_timeout_and_slowness` | Fails unless the below-timeout slow case receives the configured slowness classification independently of timeout. | Uses the production Buck test rule and real declared nextest toolchain. |
| Output capture | `buck2_nextest_output_capture` | Fails unless per-test stdout/stderr visibility follows the selected nextest capture policy without runner parsing. | Uses the production Buck test rule and real declared nextest toolchain. |
| Ignored tests | `buck2_nextest_ignored_tests` | Fails unless default and explicitly included ignored-test behavior differ as configured and JUnit reports each accurately. | Uses the production Buck test rule and real declared nextest toolchain. |
| Groups and concurrency | `buck2_nextest_group_concurrency` | Fails unless group limits constrain overlap while permitted tests execute concurrently. | Uses the production Buck test rule and real declared nextest toolchain. |
| Cancellation and no orphans | `buck2_nextest_cancellation_cleanup` | Fail-closed probe; becomes passing evidence only when outer cancellation reaches a controllable nextest process boundary and no descendant survives. | Uses the production Buck test rule and real declared nextest toolchain. |
| Live remote platform and materialization | `buck2_nextest_remote_platform_and_materialization` | Fails unless a fresh non-cache-hit Execute carries declared platform properties and exact outputs materialize. | Uses the production Buck test rule and real declared nextest toolchain. |

**Risks/decision triggers.** If the documented nextest CLI cannot express an
independently asserted feature, investigate upstream nextest before narrowing
the integration. Do not preemptively embed or fork nextest.

<a id="simplify-compatibility"></a>
## 9. Retire obsolete compatibility surfaces

**Purpose and evidence.** Current code mutates captured baseline JSON, exposes
low-level record declarations, and asks consumers to provide Cargo/Python,
arbitrary bundle resources, and digests. Some fault seams and source-grep tests
pin implementation rather than behavior.

**Desired end state.** After the provider-backed consumer rule has behavioral
replacements, make `nextest_buck_test_binary` internal or remove it rather than
keeping the record rule as a co-equal public API. Generate supported metadata
explicitly; retain baselines only as upstream compatibility/regeneration
evidence; remove unnecessary consumer inputs and implementation-only seams.
There are no consumers, so backward-compatibility work is not required, but
removal still waits for replacement evidence.

**Implementation boundaries.** Reassess Cargo/Python inputs, mandatory bundle
resources, digests, baseline mutation, fault injection, toolchain baseline, and
fault seams separately from the selected public declaration shape. Do not remove
the working production slice before the new consumer, provider, manifest,
relocation, source-denial, status, JUnit, and real-toolchain checks replace it.
The former executor sentinel is intentionally removed from the Rust runtime;
process-group and status behavior are covered by native lifecycle tests instead.

**Dependencies/order.** Retire compatibility only after
`buck2_nextest_consumer_surface`, provider/runtime evidence, and stable behavioral
replacements pass. Remove implementation-pinning checks only when the replacement
would independently fail on the protected regression.

**Acceptance evidence.** The public fixture requires only ordinary `rust_test`
targets and one `nextest_test`; the low-level record target is absent from the
public setup while all behavioral gates continue to pass. A dedicated
executor-sentinel regression must precede changing
`BUCK2_NEXTEST_TEST_EXECUTOR`.

**Risks/decision triggers.** Upstream metadata requirements determine which
baselines remain. Evidence may retain internal compatibility machinery, but it
must not silently preserve a co-equal consumer API.

<a id="reassess-and-resume-remote"></a>
## 10. Reassess integration and resume remote validation

**Purpose and evidence.** The current CLI/remap path has not yet been tested
against a generic realistic closure, while Phase 8's live request reached the
backend without propagated platform properties.

**Desired end state.** Decide from local evidence whether the documented CLI and
remap surface is sufficient, an upstream standalone manifest is warranted, or
deeper integration is required. Then complete live remote platform propagation,
runtime materialization, descendant cancellation, failed-result retrieval, and
cache-behavior validation.

**Implementation boundaries.** Do not infer the need for embedding, forking,
per-test Buck delegation, workers, persistent records, or richer protocols from
the fixture. Preserve the fail-closed gate and do not confuse submission evidence
with worker-side execution.

**Dependencies/order.** Requires the local generic production path, real declared
toolchain, realistic runtime closure, core feature evidence, and cancellation
cleanup. This is the point at which the temporary remote freeze ends.

**Acceptance evidence.** `buck2_nextest_remote_platform_and_materialization`,
using the production Buck test rule and real declared nextest toolchain, must
observe a fresh Execute carrying declared properties, matching a supported
worker, exact runtime/result materialization, process-tree cancellation, failed
result handling, and separately observable cache behavior.

**Risks/decision triggers.** Current Buck2/nextest API and backend research plus
an operator-reviewed integration decision are required. A narrower integration
is justified only by measured CLI limitations.

## Quick-cleanup assertion matrix

This checked-in matrix is authoritative for the quick-cleanup candidates
`nextest_buck_artifact_rule_contract.sh`, `scenario_removed.sh`, and
`legacy_path_absent.sh`. Each row names one explicit assertion (including each
loop or embedded-Python assertion). `retain` means the assertion remains a
current guarantee; `delete` would mean that the assertion and, only when every
assertion in its script is `delete`, its script and associated registrations
could be removed. No Buck introspection is inferred from source text: the
rule-policy assertions remain because no existing stable observable action or
action-policy check covers all three policy facts together.

| Script | Exact guarded condition | Current guarantee vs completed migration | Disposition exactly `retain` or `delete` | Replacement behavioral/current-contract check | Affected BUCK/Justfile/README/docs references |
|---|---|---|---|---|---|
| `nextest_buck_artifact_rule_contract.sh` | `[ -f "$rule" ]` | Current guard that the supplied rule resource exists before contract checks. | `retain` | None; the dedicated contract target is the current check. | `BUCK:412-416` (`//:nextest_buck_artifact_rule_contract`, `nextest.bzl` resource); `Justfile:40,189-190`; `README.md:59,63`; `docs/smoke_documentation.sh:31`. |
| `nextest_buck_artifact_rule_contract.sh` | `grep -F '"--profile", ctx.attrs.profile' "$rule"` succeeds. | Current guarantee that the profile attribute is forwarded to the adapter action. | `retain` | `nextest_buck_artifact_action_inspection.py:57-70` observes `--profile` in every declared action, but does not replace the source contract's exact attribute expression. | `BUCK:412-416`; `Justfile:40,189-190`; `README.md:36,59`; `docs/baseline-and-manifest.md:53`; `docs/smoke_documentation.sh:16`. |
| `nextest_buck_artifact_rule_contract.sh` | `grep -F '"--filter", ctx.attrs.filter' "$rule"` succeeds. | Current guarantee that the filter attribute is forwarded to the adapter action. | `retain` | `nextest_buck_artifact_action_inspection.py:57-70` observes `--filter` in every declared action, but does not replace the source contract's exact attribute expression. | `BUCK:412-416`; `Justfile:40,189-190`; `README.md:36,59`; `docs/baseline-and-manifest.md:53`; `docs/smoke_documentation.sh:16`. |
| `nextest_buck_artifact_rule_contract.sh` | `grep -F '"--no-tests", ctx.attrs.no_tests' "$rule"` succeeds. | Current guarantee that the no-tests policy attribute is forwarded to the adapter action. | `retain` | `nextest_buck_artifact_action_inspection.py:57-70` observes `--no-tests` in every declared action, but does not replace the source contract's exact attribute expression. | `BUCK:412-416`; `Justfile:40,189-190`; `README.md:36,59`; `docs/baseline-and-manifest.md:53`; `docs/smoke_documentation.sh:16`. |
| `nextest_buck_artifact_rule_contract.sh` | `grep -F '"--report-skipped", ctx.attrs.report_skipped' "$rule"` succeeds. | Current guarantee that the skipped-test reporting attribute is forwarded to the adapter action. | `retain` | `nextest_buck_artifact_action_inspection.py:57-70` observes `--report-skipped` in every declared action, but does not replace the source contract's exact attribute expression. | `BUCK:412-416`; `Justfile:40,189-190`; `README.md:36,59`; `docs/baseline-and-manifest.md:53`; `docs/smoke_documentation.sh:16`. |
| `nextest_buck_artifact_rule_contract.sh` | `grep -F '"--timeout-seconds", str(ctx.attrs.timeout_seconds)' "$rule"` succeeds. | Current guarantee that the timeout attribute is stringified and forwarded to the adapter action. | `retain` | `nextest_buck_artifact_action_inspection.py:57-70` observes `--timeout-seconds` in every declared action, but does not replace the source contract's exact attribute expression. | `BUCK:412-416`; `Justfile:40,189-190`; `README.md:36,59`; `docs/baseline-and-manifest.md:53`; `docs/smoke_documentation.sh:16`. |
| `nextest_buck_artifact_rule_contract.sh` | `grep -F 'prefer_local = True' "$rule"` succeeds. | Unique current Buck scheduling guarantee: the declared action is local-preferred. This is not merely completed migration prose. | `retain` | `nextest_buck_artifact_junit_local.sh:35-50` observes local execution for the default action, but does not cover the source policy together with the other two facts. | `BUCK:412-416`; `Justfile:40,189-190`; `README.md:59,127`; `docs/baseline-and-manifest.md:59,63`; `docs/smoke_documentation.sh:24,31`. |
| `nextest_buck_artifact_rule_contract.sh` | `! grep -F 'local_only = True' "$rule"` succeeds. | Unique current Buck scheduling guarantee: the action is not forced local-only, preserving explicit caller-selected remote behavior. | `retain` | `nextest_buck_artifact_junit_local.sh:51-52` explicitly says its local observation is not an absolute local-only guarantee; no replacement covers this absence. | `BUCK:412-416`; `Justfile:40,189-190`; `README.md:59,127`; `docs/baseline-and-manifest.md:59,63`; `docs/smoke_documentation.sh:35`. |
| `nextest_buck_artifact_rule_contract.sh` | `grep -F 'allow_cache_upload = False' "$rule"` succeeds. | Unique current cache-safety guarantee: the action cannot upload its cache result. | `retain` | `docs/smoke_documentation.sh:31` checks the same source fact, but is documentation smoke rather than a replacement action-policy test; no stable observable check covers the full trio. | `BUCK:412-416`; `Justfile:40,189-190`; `README.md:63,127`; `docs/baseline-and-manifest.md:63`; `docs/smoke_documentation.sh:31`. |
| `nextest_buck_artifact_rule_contract.sh` | `grep -F 'bundle-json' "$rule"` succeeds. | Current guarantee that the declared toolchain bundle manifest is passed to the runner. | `retain` | `nextest_buck_artifact_action_inspection.py:67-91` observes bundle arguments and validates the decoded bundle contract. | `BUCK:412-416`; `Justfile:40,189-190`; `README.md:59`; `docs/baseline-and-manifest.md:59,63`; `docs/smoke_documentation.sh:31`. |
| `nextest_buck_artifact_rule_contract.sh` | `grep -F 'bundle-resources' "$rule"` succeeds. | Current guarantee that declared bundle resources are passed to the runner. | `retain` | `nextest_buck_artifact_action_inspection.py:67-91` observes bundle-resource arguments and validates the decoded bundle contract. | `BUCK:412-416`; `Justfile:40,189-190`; `README.md:59`; `docs/baseline-and-manifest.md:59,63`. |
| `nextest_buck_artifact_rule_contract.sh` | `grep -F 'local-fixture-v1' "${BUCK_PROJECT_ROOT:-.}/toolchains/BUCK"` succeeds. | Current fixture toolchain contract: the default toolchain exposes a non-empty local platform identity. | `retain` | `nextest_buck_artifact_action_inspection.py:82-88` validates the decoded `local-fixture-v*` platform and resource digest. | `BUCK:412-416`; `Justfile:40,189-190`; `README.md:59,123`; `docs/baseline-and-manifest.md:59,63`. |
| `scenario_removed.sh` | `[ -d "$project" ]` succeeds. | Current guard that the repository root exists before the repository-wide migration scan. | `retain` | None; this is setup validation for the unique repository-wide scan. | `BUCK:458-462`; `Justfile:48,205-206`; `README.md: none`; `docs/smoke_documentation.sh:72-73`. |
| `scenario_removed.sh` | Python splits the bytes from `git -C "$project" ls-files -z -- '*.sh' '*.bzl' 'BUCK' 'README.md' 'docs/*.md' 'docs/*.sh'` on NUL and rejects an empty `files` list. | Current guard that the tracked source/documentation set is non-empty, so the migration scan cannot pass vacuously, while preserving arbitrary tracked filenames. | `retain` | None; no behavioral check proves a non-empty, NUL-safe repository-wide scan. | `BUCK:458-462`; `Justfile:48,205-206`; `README.md: none`; `docs/smoke_documentation.sh:72-73`. |
| `scenario_removed.sh` | For every present tracked matching file, its bytes must not contain the legacy switch constructed from the two byte fragments `b"--"` and `b"scenario"`; missing tracked paths are treated as pending deletions. | Unique current repository-wide guarantee that the removed scenario option is absent from tracked shell, Starlark, BUCK, README, and docs files. The migration is complete, but reintroduction remains regression-relevant. | `retain` | `docs/smoke_documentation.sh:72-73` checks the same constructed option only in README/baseline/roadmap, not every tracked matching file; `adapter_mode_validation.sh:27,76` checks the user-facing unknown-option behavior, not source-wide absence. | `BUCK:458-462`; `Justfile:48,205-206`; `README.md: no direct target reference`; `docs/smoke_documentation.sh:72-73`; `docs/roadmap-follow-ups.md` (this matrix). |
| `legacy_path_absent.sh` | `! grep -F 'cargo-fixture' "$root/adapter.sh"` succeeds. | Unique current guarantee that the adapter has no legacy `cargo-fixture` execution path. The migration is complete, but source denial of that path remains relevant. | `retain` | `adapter_mode_validation.sh:27,76` verifies `cargo-fixture` is rejected as an unknown mode, but does not prove the adapter source has no legacy branch. | `BUCK:464-473`; `Justfile:19,145-146`; `README.md:123`; `docs/baseline-and-manifest.md:11`; `docs/smoke_documentation.sh:87`. |
| `legacy_path_absent.sh` | `! grep -F 'nextest_spike' "$root/BUCK"` succeeds. | Current guarantee that the obsolete `nextest_spike` Buck target is not registered; completed migration is still protected against target reintroduction. | `retain` | `docs/smoke_documentation.sh:88` checks the same absence only in README/baseline/roadmap, not the BUCK target. | `BUCK:464-473`; `Justfile:19,145-146`; `README.md: none`; `docs/smoke_documentation.sh:88`. |
| `legacy_path_absent.sh` | `! grep -F 'cargo-fixture' "$root/BUCK"` succeeds. | Current guarantee that the obsolete mode is not wired as a Buck target/resource; completed migration is still protected against reintroduction. | `retain` | `adapter_mode_validation.sh:27,76` covers runtime rejection, but no behavioral check proves the Buck graph lacks the legacy string. | `BUCK:464-473`; `Justfile:19,145-146`; `README.md:123`; `docs/smoke_documentation.sh:87`. |
| `legacy_path_absent.sh` | In the extracted `nextest_buck_artifact_runner` block, `assert 'fixture/' not in block`. | Unique current guarantee that the supported runner resource closure does not include the observation fixture directory. The fixture migration is complete, while the supported closure boundary remains current. | `retain` | `nextest_buck_artifact_consumer_inspection.py` and `adapter_relocated_sanitized.sh` prove declared-input closure behavior, but do not replace this exact runner-resource exclusion. | `BUCK:464-473`; `Justfile:19,145-146`; `README.md:123`; `docs/baseline-and-manifest.md:11`; `docs/smoke_documentation.sh:87`. |
| `legacy_path_absent.sh` | In the extracted `nextest_buck_artifact_runner` block, `assert 'buck_artifact_export_fault.sh' not in block`. | Unique current guarantee that the fault-injection helper is not part of the supported runner resource closure. Fault tests remain separate test resources. | `retain` | `BUCK:257-277` keeps `buck_artifact_export_fault.sh` scoped to report-destination tests; no behavioral check replaces the runner-block exclusion. | `BUCK:464-473,257-277`; `Justfile:19,145-146`; `README.md: none`; `docs/roadmap-follow-ups.md` (this matrix). |
| `legacy_path_absent.sh` | `[ -f "$root/fixture/Cargo.toml" ]` succeeds. | Current guarantee that the checked-in Cargo fixture remains available for observation/baseline regeneration, despite not being an execution resource. | `retain` | `docs/baseline-and-manifest.md:7-19` documents the observation contract, but does not provide an executable existence check. | `BUCK:1-4,464-473`; `Justfile:19,145-146`; `README.md:123`; `docs/baseline-and-manifest.md:7-19`; `docs/smoke_documentation.sh:11,123-related prose`. |
| `legacy_path_absent.sh` | `[ -f "$root/tools/capture_cargo_nextest_baseline.sh" ]` succeeds. | Current guarantee that the baseline observation/regeneration tool remains available; it is not a supported execution path. | `retain` | `docs/baseline-and-manifest.md:7-19` documents the regeneration contract, but does not provide an executable existence check. | `BUCK:464-473`; `Justfile:19,145-146`; `README.md:123`; `docs/baseline-and-manifest.md:7-19`; `docs/smoke_documentation.sh:11`. |

All three candidate scripts therefore remain registered; no script has every
assertion obsolete or replaced, so Cleanup C removes no script, target,
resource, recipe, CI entry, or stale smoke/prose reference.

## Prioritization

| Group | Work |
|---|---|
| **next** | Clean disposable Buck isolations; preserve the remote-expansion freeze; pass `buck2_nextest_rust_provider_compatibility`; establish provider-backed `nextest_test`; prove `buck2_nextest_consumer_surface`; then prove the real declared nextest path and realistic provider-derived runtime closure. |
| **after the local production path** | Prove core nextest features; retire obsolete low-level compatibility surfaces after behavioral replacements; reassess the integration; resume live RE platform, materialization, cancellation, failed-result, and cache validation. |
| **deferred until evidence requires it** | Direct nextest embedding or forking; global transforming executor; macro-only canonical API; automatic package discovery; per-test Buck delegation; persistent workers; persistent nextest records; richer event/result protocols. |
