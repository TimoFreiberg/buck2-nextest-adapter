# Buck2/nextest integration roadmap

## Current position

The repository now proves a local Buck2-built artifact handoff:

```text
Buck2 rust_test
  -> declared version-1 manifest + Buck output
       -> POSIX adapter
            -> supplied Cargo/nextest metadata
                 -> cargo nextest list/run
```

The legacy Cargo-fixture regression remains available separately. The new path
proves one native Buck2 Rust executable, synthetic identity for `pass_case` and
`fail_case`, one static declared runtime input, manifest-driven cwd/environment,
rooted staging, deterministic diagnostic output controls, metadata-only list/run
commands for the installed nextest CLI, and exit-status propagation. The Cargo baseline's two
integration binaries are observations mapped to one Buck-owned binary.

Result reporting, advanced nextest features, and remote execution remain
unproven. In particular, retries, timeouts, groups, JUnit XML/full status
mapping, generated outputs, shared libraries, cancellation redesign, direct
embedding, native provider promotion, and richer event protocols are not part of
this boundary. JUnit XML is a deferred reporting surface, not discovery metadata
or an execution protocol. Remote execution remains unproven.

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

### 5. Add result reporting and status mapping

Define the adapter's stable result boundary:

- Preserve nextest's documented process exit semantics.
- Convert or pass through JUnit XML for Buck2/CI ingestion.
- Define behavior for skipped, ignored, filtered, timed-out, and aborted tests.
- Keep human-readable output diagnostic only.
- Do not use experimental libtest JSON, internal event recordings, or an
  invented event stream as the initial protocol.

**Deliverable:** documented status and reporting rules, with fixture coverage
for pass, failure, skip, timeout, and no-tests-selected behavior.

### 6. Exercise nextest features against Buck2 metadata

Once basic execution is stable, validate features that depend on runtime and
identity metadata:

- Retries.
- Timeouts.
- Test groups and scheduling.
- Output capture modes.
- Target runners and platform selection.
- Build scripts and dynamic libraries.
- Cancellation and process-tree cleanup.

Each feature needs an explicit acceptance test. Do not assume Cargo behavior
continues to hold when artifacts and metadata come from Buck2.

### 7. Validate sandboxing and remote-like execution

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

### 8. Reassess the long-term integration surface

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

Start Phase 5 with a bounded reporting and status-design follow-up: define the
JUnit XML boundary and full skipped/ignored/filtered/timed-out/aborted/no-tests
status mapping, then add fixture coverage without changing the Phase 4 local
artifact contract. Keep retries, remote execution, direct embedding, and richer
event protocols as separate follow-ups.
