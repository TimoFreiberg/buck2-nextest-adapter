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

**Dependencies/order.** Resume remote work only after follow-ups 2, 3, 5, and 6
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
current action is documented history and must not be silently removed or
promoted by this roadmap update.

**Desired end state.** A reusable Buck2 test rule/provider runs fresh nextest
execution through `buck2 test`, with Buck owning declared inputs, outputs,
resources, and cancellation while nextest retains per-test execution authority.

**Implementation boundaries.** This change neither removes nor promotes the
existing declared JUnit build action. Before either surface changes, an
operator-approved decision record must name the owner/approver, selected outcome, passing evidence, migration/documentation consequences, and explicit removal or support boundary. The selected outcome must be one of: classify and remove the
old action as temporary, retain it as a separately documented optional reporting
API, or keep it supported. The evidence must cover the real toolchain, documented
statuses, unchanged JUnit bytes and diagnostics, cancellation, and fresh-execution
lifecycle. No implementation may remove, promote, or leave both surfaces
indefinitely ambiguous before that record exists.

**Dependencies/order.** Settle this interface together with the generic contract
in follow-up 3 before rewriting the runner. Its production rule is required by
all later acceptance tests.

**Acceptance evidence.** `buck2_nextest_real_declared_toolchain` must run through
the production Buck test rule and real declared nextest toolchain. Additional
lifecycle assertions must prove repeated `buck2 test` execution is not
accidentally satisfied by a normal build cache, statuses remain documented,
diagnostics remain Buck-owned, and exact JUnit bytes are unchanged. The
explicit `buck2_nextest_cancellation_cleanup` probe remains fail-closed, but it
is deferred as passing evidence until the Buck-to-runner-to-nextest boundary
can prove cancellation and descendant quiescence.

**Risks/decision triggers.** Buck2 test-provider and executor APIs require fresh
research. The operator decision gate is mandatory after the named evidence
passes and before changing the old action's status.

<a id="generic-artifact-runtime-contract"></a>
## 3. Generalize the artifact/runtime contract

**Purpose and evidence.** `adapter/src/manifest_v1.rs` and the Rust runner encode
validated metadata and declared staging. A reusable rule needs
arbitrary one-or-more test-binary records supplied by supported Buck providers
or a minimal explicit wrapper/provider.

**Desired end state.** Each record carries package identity, the
configuration-independent canonical Buck owner label in cell/package/target
form, binary identity, a non-unique display name, exactly one executable
artifact, runtime artifacts, platform, and generated/runtime outputs. Schema v2
maps each package identity to one normalized package-scoped cwd; suite
environment is supplied once by `nextest_buck_test`, not repeated per record.
The uniqueness key is exactly `(package identity, canonical Buck target label, binary identity)`. Cargo package IDs and nextest binary IDs are generated
deterministically and reversibly from that semantic triple. Filters map through
those generated package and binary identities plus test names discovered by
nextest.

**Implementation boundaries.** Display name, executable basename, and filesystem
path are excluded from identity. Reject missing fields, duplicate triples, duplicate executable association, multiple-executable record, and normalization/encoding collision before staging. In particular, reject one executable associated with multiple records and multiple executables in one record. Nextest `list` output is
the sole source of test-case names for execution; do not consume checked-in or
build-time test-name lists unless a demonstrated Buck listing API requirement
triggers a separately approved design. Provider/wrapper semantic sources must be
independent of exact future API field names. Only exact supported-provider field names and collision-free encoding mechanics are deferred; those decisions may not change the semantic identity rules. Never infer closure by scanning ambient
state or guessing filesystem layout.

**Dependencies/order.** Settle this contract and follow-up 2 before the Rust
runner. Follow-ups 5 and 6 prove progressively stronger declared closures.

**Acceptance evidence.** `buck2_nextest_generic_multi_binary`, using the
production Buck test rule and real declared nextest toolchain, must cover same
display names across targets and multiple binaries owned by one target without
ambiguous dispatch or duplicated test-name metadata. Separate assertions must
fail for each invalid record form and for non-reversible or colliding generated
identities.

**Risks/decision triggers.** Fresh Buck Rust provider/API research determines
field names or whether a minimal wrapper is necessary. Encoding syntax needs a
collision analysis, not ad hoc normalization.

<a id="rust-runner"></a>
## 4. Implement a Rust runner

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

**Dependencies/order.** Begin only after follow-ups 2 and 3 settle the Buck and
manifest interfaces. Preserve existing status/JUnit behavior while replacing the
implementation.

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
## 5. Prove real nextest through the declared production path

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
closure in follow-up 6.

**Dependencies/order.** Requires the production test surface and generic
contract. It precedes realistic closure and all renewed RE work.

**Acceptance evidence.** `buck2_nextest_real_declared_toolchain`, using the
production Buck test rule and real declared nextest toolchain, must fail if list
or run is stubbed, any undeclared host tool/support file is used, scratch escapes
Buck ownership, or JUnit bytes change.

**Risks/decision triggers.** Toolchain packaging may require current nextest and
Buck executable-provider research, but cannot relax the ambient-input boundary.

<a id="realistic-rust-runtime-closure"></a>
## 6. Support a realistic Buck Rust runtime closure

**Purpose and evidence.** This increment closes the first provider-runtime
slice: the production `nextest_buck_test` path consumes the Rust executable's
`DistInfo.nondebug_runtime_files`, and a generated Rust `resources` edge is
available at the executable-relative native path. The positive production
scenario passes through real cargo-nextest; the otherwise identical no-resource
scenario reaches the named test and publishes its stable missing-resource
failure. Shared libraries, build-script outputs, provider-derived environment
and platform/runner metadata, and broader transitive semantics remain unproved.

**Desired end state.** Extend the established provider authority to shared
libraries, generated/build-script outputs, runtime data, environment,
platform/runner information, and other transitive runtime artifacts from
supported Buck Rust providers or a minimal explicit wrapper, without adding
consumer-authored layout or ambient fallback.

**Implementation boundaries.** Never guess output layout, scan `buck-out`, or
use ambient state. Buck remains authoritative for the complete closure and
nextest receives only declared executable/runtime records.

**Dependencies/order.** Follow the fixture/toolchain proof in follow-up 5 and use
the generic record contract from follow-up 3.

**Acceptance evidence.** The completed `buck2_nextest_runtime_closure`, using
the production Buck test rule and real declared nextest toolchain, proves a
Buck-generated Rust `resources` dependency and fails when that specific provider
edge is removed. The registered provider/action contract additionally proves the
positive `DistInfo` closure is materialized without a packaging or staging action.
This closes only the generated-resource/provider-file portion; a future
extension must independently prove shared-library or build-script-specific
behavior and any provider-derived environment/platform semantics before this
broad follow-up is complete.

**Risks/decision triggers.** Fresh provider investigation decides whether current
Buck Rust providers expose enough information or a minimal wrapper is needed.

<a id="core-nextest-value"></a>
## 7. Prove the core nextest value proposition

**Purpose and evidence.** The current Phase 7 list has no production-path proof
for the features that justify nextest: process isolation, retry, timeout,
slowness, capture, ignored tests, and group concurrency.

**Desired end state.** End-to-end tests demonstrate those behaviors and a
realistic runtime dependency through the exact production rule and toolchain,
without moving per-test scheduling into Buck or the runner.

**Implementation boundaries.** Nextest owns discovery, per-test processes,
retry, timeout/slowness, grouping/scheduling intent, capture, and JUnit. Buck
owns global resources and the enclosing action. Combined scenarios are allowed,
but every behavior needs an independently failing assertion.

**Dependencies/order.** Requires follow-ups 2, 3, 5, and 6. It precedes claims
of production usefulness and resumed remote validation.

**Acceptance evidence.** The feature-to-test matrix below is authoritative for
future product coverage.

### Feature-to-test matrix

Every row uses the production Buck test rule and real declared nextest toolchain.
A shared check name never permits a shared, non-specific assertion.

| Feature | Named future check | Regression-sensitive assertion | Production-path constraint |
|---|---|---|---|
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
## 8. Simplify the compatibility layer and consumer setup

**Purpose and evidence.** Current code mutates captured baseline JSON and asks
consumers to provide Cargo/Python, arbitrary bundle resources, and digests. Some
fault seams and source-grep tests pin implementation rather than behavior.

**Desired end state.** Generate supported metadata explicitly; retain baselines
only as upstream compatibility/regeneration evidence. Remove inputs and
consumer-authored identity data that Buck artifact identity makes unnecessary,
and consolidate product seams only where behavioral tests replace them.

**Implementation boundaries.** Reassess Cargo/Python inputs, mandatory bundle
resources, digests, baseline mutation, and fault injection separately. Do not
remove current behavior merely because there are no users. In particular,
The former executor sentinel is intentionally removed from the Rust runtime;
process-group and status behavior are covered by native lifecycle tests instead.

**Dependencies/order.** Simplify after the production surface and generic
contract expose which compatibility pieces remain necessary. Retire
implementation-pinning checks only after stable behavioral replacements exist.

**Acceptance evidence.** Consumer fixtures must require fewer authored inputs
while all manifest validation, relocation, source-denial, status, JUnit, and
real-toolchain checks continue to pass. A dedicated executor-sentinel regression
must precede changing `BUCK2_NEXTEST_TEST_EXECUTOR`.

**Risks/decision triggers.** Upstream metadata requirements determine which
baselines remain. Any removal that changes adapter or provider contracts needs a
separate operator-reviewed implementation decision.

<a id="reassess-and-resume-remote"></a>
## 9. Reassess integration and resume remote validation

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
| **next** | Clean disposable Buck isolations after each test; freeze additional RE expansion; define the primary Buck test surface; generalize the artifact/runtime contract; then implement the Rust runner; prove the real declared nextest fixture/toolchain path. |
| **after the local production path** | Support realistic Rust runtime closure; prove core nextest features; simplify compatibility and consumer setup; reassess the integration; resume live RE platform, materialization, cancellation, failed-result, and cache validation. |
| **deferred until evidence requires it** | Direct nextest embedding or forking; per-test Buck delegation; persistent workers; persistent nextest records; richer event/result protocols. |
