**This is the result of a discussion session that resulted in this repo idea**

---

Your intuition is largely right: there is no fundamental requirement that Buck2 directly spawn every test process. A test runner can plausibly spawn and manage the actual tests, while Buck2 supervises the runner and receives aggregate or per-test results.

The distinction is mostly about what guarantees Buck2 wants to provide.

## Local execution ##

For local execution, this model is reasonable:
Buck2
  └─ starts buck2-nextest-runner
       ├─ starts test 1
       ├─ starts test 2
       └─ reports results to Buck2

The runner can own:

• test-process spawning,
• process groups,
• retries,
• output capture,
• timeouts,
• termination,
• scheduling,
• result aggregation.

Buck2 can treat the runner as the externally managed test job.

This is probably the most natural way to preserve nextest’s current executor. It avoids forcing nextest to turn every process operation into a Buck2 RPC immediately.

## What Buck2 may lose locally ##

The concern is not whether child processes can technically be spawned. It is whether Buck2 can still enforce and observe its execution guarantees.

If the runner spawns children directly, Buck2 may not automatically know:

• how many processes exist,
• how much CPU or memory they consume,
• which child produced which output,
• whether grandchildren remain alive,
• whether all descendants terminate,
• how to kill the complete process tree,
• whether a test accesses undeclared files,
• how to attribute resource usage,
• whether the runner respects Buck2’s local-resource reservations.

These are manageable if the runner is treated as a process-tree supervisor and Buck2’s contract permits that model. nextest already has substantial process-tree and leak-handling logic, so this is not an inherently weak design.

The runner should at least:

• keep all test processes in controllable process groups or job objects,
• terminate descendants when the runner is cancelled,
• propagate runner shutdown to all tests,
• avoid orphaning grandchildren,
• ensure captured file descriptors are closed,
• return a meaningful result if the runner itself is killed.

## Remote execution changes the answer ##

For remote execution, the important question is where the runner itself runs.

### Case 1: runner runs inside the remote execution ###
Buck2
  └─ remote action
       └─ buck2-nextest-runner
            └─ test processes

This can work if the remote execution environment permits the runner to spawn child processes and if the remote executor tracks the entire process tree.

However, there may be limitations:

• Some remote executors expect the action’s declared command to be the complete process tree.
• Some sandbox implementations do not provide robust descendant tracking.
• Resource accounting may apply only to the action as a whole.
• Remote cancellation must reliably kill the runner and all descendants.
• Test processes must have all binaries, libraries, and data available in the remote sandbox.
• Individual test results may only become visible after the runner exits unless a streaming protocol exists.

This is still a plausible design. It is not automatically invalid.

### Case 2: runner runs locally and delegates each test to Buck2 ###
Local external runner
  └─ Buck2 execution request
       └─ remote test process

This is the more powerful model for per-test remote execution, but it introduces a second execution protocol inside the external runner.

Conceptually:
Buck2
  └─ external nextest runner
       ├─ asks Buck2 to execute test A remotely
       ├─ asks Buck2 to execute test B remotely
       └─ reports results back to the outer Buck2 test invocation

Yes, this is possible in principle, and your timeout/cancellation idea is the right one. But it is not merely “Buck2 keeps a handle.” The runner would need a well-defined execution capability with:

• command/artifact handles,
• environment and working directory,
• executor selection,
• local-resource requirements,
• timeout,
• cancellation,
• stdout/stderr capture,
• exit status,
• signal or termination reason,
• completion notification,
• perhaps live output/events.

The outer Buck2 invocation must also distinguish:
external runner failed

from:
a delegated test failed

and from:
the whole run was cancelled

## The Buck2 → runner → Buck2 loop ##

The loop is architecturally plausible:
Buck2 test command
  → nextest runner
      → Buck2 execution request for test
          → result
      → retry or schedule another test
  → final results to Buck2

But there are several hazards.

### 1. Recursive test-runner selection ###

The delegated command must be an ordinary execution request, not another `buck2 test` invocation. Otherwise you could recursively invoke the external test runner:
Buck2 test
  → nextest runner
      → Buck2 test
          → nextest runner
              → ...

The inner request should be a lower-level command execution API, equivalent to “execute this action,” not “run this test target through the test framework.”

### 2. Buck2 scheduling deadlock ###

Suppose Buck2 reserves one worker slot for the external runner, and the runner asks Buck2 to execute tests. If Buck2 cannot schedule nested requests while the outer runner occupies that slot, the system can deadlock.

The protocol needs explicit support for reentrant or nested execution, or the outer runner must not consume a scarce execution slot in a way that blocks its delegated children.

### 3. Double scheduling ###

There would be two schedulers:

• nextest decides how many tests to run concurrently.
• Buck2 decides how many execution requests to admit concurrently.

If both independently enforce concurrency, you could get:

• underutilization,
• oversubscription,
• priority inversions,
• deadlocks involving test groups or resources.

The clean design would let nextest express scheduling intent while Buck2 remains authoritative for global capacity and resource constraints.

### 4. Timeout layering ###

There may be at least three timeouts:
outer Buck2 test timeout
  └─ runner timeout
       └─ delegated test timeout

They need clear semantics:

• If the delegated test timeout expires, nextest should classify the test as timed out and perhaps retry it.
• If the runner timeout expires, the runner must cancel all outstanding requests.
• If the outer Buck2 timeout expires, Buck2 must cancel the runner and all delegated requests.
• Cancellation must be idempotent and race-safe.

A test may finish successfully at the same moment its timeout cancellation is delivered. The protocol needs a clear winner and consistent result mapping.

### 5. Output and event streaming ###

If delegated execution returns only after completion, nextest can still implement retries and final reporting, but live progress is harder.

For a good integration, the execution handle should ideally support:

• incremental stdout/stderr,
• process-start notification,
• completion,
• cancellation,
• perhaps resource or timing metadata.

Without streaming, Buck2 can still receive final results, but the user experience may be less responsive.

## What this implies for nextest architecture ##

This means that nextest-owned process spawning is not necessarily the final architectural problem. It is one execution backend.

A better abstraction might be:
trait TestExecutor {
    type Handle;

    fn execute(&self, request: TestExecutionRequest) -> Handle;
    fn cancel(&self, handle: &mut Self::Handle);
    // receive completion/output events
}

Then:
LocalProcessExecutor
  → nextest spawns and manages processes

Buck2Executor
  → nextest submits commands to Buck2 and manages handles

Possibly other executor backends

The scheduler, retry policy, test-group logic, and reporting can be shared above that boundary.

The local backend can preserve current nextest behavior. The Buck2 backend can delegate execution when remote execution or Buck2 resource management is needed.

## Recommended architecture ##

I would now refine the earlier recommendation:

### First implementation ###

Use nextest-owned process spawning inside a Buck2 external runner:
Buck2 starts runner
runner starts nextest
nextest starts tests
runner reports results

This is the shortest path to testing the value proposition. It should work locally and may work remotely if the runner itself executes inside the remote action and process-tree behavior is adequate.

### Later execution backend ###

Add a Buck2 delegation backend only if you need:

• per-test remote execution,
• Buck2 resource providers,
• Buck2-specific sandboxing,
• Buck2-level action caching or accounting,
• stronger integration with execution platforms.

Then the architecture becomes:
nextest scheduler/reporter
  ├─ local process execution backend
  └─ Buck2 delegated execution backend

This avoids making all nextest users depend on Buck2 semantics.

## One important caveat: caching ##

Buck2’s normal action model may want execution results to be cacheable based on declared inputs and command identity. A nextest run that dynamically retries, schedules, captures output, and spawns many child processes may not map neatly onto one cacheable action.

That does not prevent the integration, but it may mean:

• Buck2 caches artifact builds, not individual test results.
• The runner remains responsible for test result persistence.
• Remote execution is used for isolation and capacity rather than ordinary action caching.
• Test retries are not represented as independent Buck2 actions unless delegated execution is used.

## Bottom line ##

Your proposed model is viable:
> Buck2 supervises the nextest runner; nextest supervises local test processes. For remote/per-test execution, nextest submits cancellable execution requests back to Buck2.

That is probably a better architecture than insisting Buck2 directly own every test process.

The main requirements are:

1. The external-runner protocol must permit the runner to manage child processes.
2. Buck2 must reliably terminate the runner’s descendants.
3. Nested Buck2 execution requests must be supported without scheduler deadlock.
4. Delegated execution needs explicit timeout and cancellation handles.
5. Concurrency and resource ownership must be coordinated between nextest and Buck2.
6. The inner request must be a command execution, not a recursive `buck2 test` request.

So I would not treat Buck2-owned process execution as a prerequisite. I would design nextest with two execution modes:

• a direct local process backend, preserving current nextest behavior;
• a Buck2 delegation backend, used when Buck2 must own remote execution or resource management.

---

# Implementation-starting context

The architecture above is viable, but the first implementation needs to account for an important constraint that is easy to miss: **normal nextest is strongly Cargo-oriented**. A Buck2-built Rust test binary cannot generally be handed directly to `cargo nextest run` and expected to work.

## What ordinary nextest expects

Nextest discovery is not based only on an executable command. It expects a Cargo-shaped build and metadata environment, including things such as:

• an existing `Cargo.toml` and Cargo package graph,
• Cargo package IDs and target kinds,
• Cargo metadata,
• nextest-compatible binary-list/build-summary data,
• binaries located beneath declared Cargo target/build directories.

`ExternalRunnerTestInfo.command` alone is therefore insufficient for discovery. The command tells Buck2 how to invoke an external runner, but it does not supply the Cargo package graph, binary IDs, artifact layout, or runtime environment that nextest normally derives from Cargo.

This means that the first prototype should not begin by assuming that a standalone Buck2 test executable can be passed directly to ordinary nextest. It should first establish how to provide the information nextest requires.

## Likely first prototype: a local compatibility adapter

A practical first step is a **local compatibility adapter**. The adapter would preserve or synthesize a Cargo-compatible workspace and artifact layout around Buck2-built artifacts, then invoke nextest through its documented CLI interface.

Conceptually:

```text
Buck2
  └─ builds Rust test artifacts
       └─ compatibility adapter
            ├─ provides Cargo-shaped metadata/layout
            ├─ invokes nextest
            └─ maps results back to Buck2
```

Depending on how much of Cargo’s output nextest requires, the adapter may need to provide or synthesize:

• package IDs,
• target kinds and binary IDs,
• binary paths under declared build/target directories,
• a workspace-root working directory,
• a nextest-compatible `BinaryList`,
• compatible `RustBuildMeta` or equivalent build metadata,
• environment variables,
• dependency and build-script outputs,
• toolchain dynamic-library paths.

A minimal wrapper could invoke a Buck2-built executable for listing and execution while exposing one synthetic binary-list record to nextest. That approach should be tested before attempting a deeper nextest integration.

The adapter should use documented nextest configuration and CLI behavior for filtering, retries, output capture, test groups, timeouts, and target runners. This keeps the initial integration on a more stable surface than direct embedding.

## Remote execution and path/runtime constraints

Remote execution makes the compatibility problem stricter. A nextest process running outside Buck2 cannot assume that it can access:

• Buck2 sandbox paths,
• Buck2 symlink trees,
• opaque argument-handle expansion,
• host-local artifact paths,
• host-local output from `rustc --print`.

For remote execution, paths should be project-relative or otherwise represented as declared Buck2 inputs. Runtime dependencies must be declared and materialized in the remote environment. This includes test binaries, shared libraries, dependency artifacts, build-script outputs, and any required toolchain libraries.

Absolute target/build directories and host-local dynamic-library paths are likely blockers unless they are explicitly represented through Buck2 inputs and environment setup. The adapter must also avoid relying on local filesystem state that is not reproduced in the remote action sandbox.

The remote questions are therefore not limited to whether the runner may spawn children. We also need to establish:

1. where the runner runs,
2. which artifacts and libraries are present there,
3. how paths are translated,
4. how the remote executor tracks and terminates descendants,
5. how cancellation and output are delivered.

## Recommended feasibility sequence

A small compatibility matrix will give the project a concrete foundation:

### 1. Capture a Cargo baseline

Run a representative Cargo/nextest project and record:

• Cargo metadata,
• Cargo JSON build messages,
• the nextest binary-list summary,
• workspace-root working directory,
• relevant environment variables,
• dynamic-library search paths,
• build-script and dependency artifacts.

The goal is to identify the minimum data nextest actually consumes, rather than reproducing Cargo more broadly than necessary.

### 2. Validate a local compatible layout

Have Buck2 build equivalent Rust artifacts and have the adapter emit or provide the Cargo/nextest-compatible metadata and layout. At minimum, test:

• test listing,
• test execution,
• shared-library dependencies,
• build scripts,
• working-directory behavior,
• environment propagation,
• retries and timeouts,
• output capture and result mapping.

This stage should answer whether the CLI-based adapter can preserve useful nextest behavior without embedding nextest internals.

### 3. Test a standalone Buck2 binary explicitly

Confirm the boundary condition: an arbitrary standalone Buck2-produced test binary is not expected to work through ordinary `cargo nextest run` unless there is a synthetic Cargo workspace/layout or a separate nextest integration surface.

This prevents the project from spending time debugging a missing metadata contract as though it were merely a process-spawning problem.

## Nextest API stability is a major constraint

Direct embedding is possible in principle, but it carries substantial maintenance risk.

`nextest-runner` has public low-level modules, yet the project treats the API as internal. Releases may introduce breaking changes, and there is no stable plugin/callback contract for replacing discovery or execution.

The `cargo-nextest` application and dispatch types are mostly `pub(crate)` and are not intended to be an embedding API. Embedding would require tight version pinning and ongoing tracking of:

• Cargo metadata assumptions,
• binary-list and build-summary formats,
• process and platform behavior,
• Tokio and concurrency details,
• cancellation and timeout semantics,
• frequent upstream changes.

The initial recommendation is therefore:

> Invoke nextest in CLI mode with a supplied Cargo-compatible environment and layout. Do not make direct embedding or a nextest fork a prerequisite for the first prototype.

A direct integration can be reconsidered after the compatibility adapter has demonstrated which contracts are genuinely needed.

## Stable result and reporting surfaces

The adapter should consume **JUnit XML** for Buck2 and CI result ingestion. It should use nextest’s documented `NextestExitCode` semantics for process-level status. Human-readable nextest output should be treated as diagnostic output, not as a machine-readable protocol.

Do not build the adapter around unstable internal formats:

• The experimental `libtest-json` and `libtest-json-plus` formats require `NEXTEST_EXPERIMENTAL_LIBTEST_JSON=1`.
• Those formats are versioned only around `0.1`, are incomplete, and may change or be removed even in patch releases.
• There is no stable first-class NDJSON event protocol.
• Internal recordings may contain event/output streams, but serialized `TestEvent` is explicitly an unstable implementation detail and should not be used as an adapter protocol.

If live progress is needed, treat it as a separate design problem rather than assuming that an internal nextest event type is a stable solution.

## Longer-term integration surface

The executor abstraction described earlier remains a useful architectural direction:

```text
nextest scheduler/reporter
  ├─ local process execution backend
  └─ Buck2 delegated execution backend
```

However, the discovery boundary may be more fundamental than the execution boundary. If Buck2 cannot provide the Cargo metadata and build layout nextest requires, the long-term answer may be an upstream adapter-facing interface—for example:

• a stable standalone binary manifest,
• an explicit runtime dependency/environment manifest,
• a documented execution request/response model,
• a stable NDJSON event protocol.

That would be preferable to depending indefinitely on nextest internals or immediately maintaining a fork. Such an interface could let Buck2 provide test discovery and execution data without pretending to be Cargo, while allowing nextest’s scheduling, retry, capture, grouping, and reporting logic to remain reusable.

## Updated first implementation recommendation

Start with the smallest useful end-to-end experiment:

1. Build one Rust test target with Buck2.
2. Create a temporary or synthetic Cargo-compatible workspace/layout.
3. Generate the minimum metadata and binary-list information nextest needs.
4. Invoke nextest through its CLI.
5. Run listing and execution locally.
6. Exercise a shared-library dependency, a build script, a timeout, a retry, and output capture.
7. Ingest JUnit XML and validate `NextestExitCode` handling.
8. Repeat the artifact/path experiment in a remote-like sandbox.

Only after this succeeds should the project decide whether it needs:

• a dedicated Buck2 execution backend,
• direct nextest embedding,
• upstream nextest changes,
• or a separate stable adapter protocol.

The core conclusion is:

> The first blocker is not whether nextest can spawn processes. It is whether Buck2 can supply—or an adapter can synthesize—the Cargo metadata, artifact layout, runtime dependencies, and stable result surfaces that ordinary nextest expects.
