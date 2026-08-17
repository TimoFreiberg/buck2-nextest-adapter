# Buck2/nextest integration roadmap

## Current position

The repository proves one canonical local Buck2-built artifact handoff:

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

The first bounded Phase 5 milestone is complete: caller-selected JUnit pass-through
and nextest process statuses are covered for pass (`0`), test failure (`100`),
ignored/skipped success, filtered-out absence, and explicit no-tests (`4`). A
post-dispatch required-export failure is adapter status `3`; pre-dispatch input
validation is `2`. Human output is diagnostic only. The separate metadata-shape
checks and explicit `nextest list` before each run are development and regression
coverage; the final integration should retain the checks that protect its
contract without assuming both steps belong in every production invocation.

This does not complete broad Phase 5 or later phases. A completed timeout remains
an ordinary JUnit `<failure>`/test-failure status with no distinct XML marker.
Process interruption, abort, and cancellation have no stable dedicated mapping
and remain deferred until a supported machine-readable/process-group contract
and test environment exist. Retries, groups, remote execution, generated outputs,
shared libraries, direct embedding, native provider promotion, and richer event
protocols also remain unproven.

## Terminology correction

The planned result format is **JUnit XML**, not Javadoc XML.

- **Binary and runtime metadata** tells the adapter/nextest what to discover
  and how to launch it.
- **JUnit XML** reports test results to Buck2 or CI after execution.
- Javadoc XML is unrelated to this test-runner integration.

JUnit XML should be treated as a reporting surface, not as a replacement for
test discovery metadata or a process-execution protocol.

## Roadmap

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
Buck2-declared inputs and outputs, followed by actual remote execution if the
Buck2 environment supports it.

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

## Recommended immediate next step

Keep the completed JUnit/status boundary stable. The deterministic completed-timeout
fixture is the bounded follow-up now complete; revisit interruption/abort/cancel
mapping only when a supported nextest machine-readable contract or a
process-group-capable test environment is available. Keep retries, groups, output
and run-state ownership, remote execution, direct embedding, and richer event
protocols as later phases.
