# Test coverage follow-up

This task list improves confidence in the observable Buck2/nextest contract without removing existing tests or changing the current coverage suite's ownership. Existing source-text, migration, documentation, and prerequisite checks remain in place; this work adds behavioral checks where the review found gaps.

## Goal

Make the test suite prove the remaining user-visible execution, configuration, and Buck integration behavior while preserving the current tests as regression coverage.

## Tasks

### 1. Cover the successful dispatch path

Add a successful real-nextest scenario that does not set `BUCK2_NEXTEST_TEST_EXECUTOR=1`.

Verify that:

- the adapter's normal top-level `cargo nextest` dispatch occurs;
- the probe path is recorded before dispatch;
- the test still completes with the documented status and JUnit report; and
- the source-denial wrapper still rejects nested Cargo and compiler activity.

Keep the existing test-executor scenarios. They cover the Buck test harness path and should continue to exercise the other assertions independently.

### 2. Cover `no-tests = auto`

Add an unmatched-filter run using `--no-tests auto` and assert the documented nextest status and report behavior. Keep the existing explicit `--no-tests fail` case as a separate check.

### 3. Cover the disabled timeout configuration

Add a captured-profile assertion for `--timeout-seconds 0`. Verify that the generated profile does not contain a `slow-timeout` table while still configuring JUnit output. Retain the existing positive timeout test.

### 4. Cover build-mode argument validation

Extend the adapter CLI validation coverage with build-mode invocations missing each required input:

- `--cargo-command`;
- `--cargo-nextest-command`;
- `--runtime-resource`; and
- `--source-denial`.

Each invocation should fail before nextest probing or dispatch with the documented validation status.

### 5. Verify report temporary-file permissions

Add a focused export test that observes the same-directory temporary report while export is blocked and verifies mode `0600`. The test must also verify that the final destination contains the expected bytes after the export completes.

Use the existing export fault gate rather than adding a permanent output or a new protocol.

### 6. Exercise the process-group prerequisite branch

When the host supports an injectable command lookup or equivalent test seam, cover `BUCK2_NEXTEST_REQUIRE_PROCESS_GROUP=1` with no available `setsid`. Verify pre-dispatch status `2` and absence of probe/dispatch activity.

On hosts where process-group tooling is unavailable, retain the existing prerequisite reporting behavior rather than claiming signal-cleanup coverage.

### 7. Strengthen toolchain behavior coverage

Add a Buck-backed check that the configured `RunInfo` toolchain executables are actually passed to the declared action and used for the successful run. Prefer action/runtime observation over source-text matching.

Keep the existing declared-output and action-identity checks.

## Acceptance criteria

- Every task has an observable behavior assertion and a stable failure message.
- Existing tests and test targets remain present and continue to run.
- New tests do not depend on exact TOML whitespace or section ordering.
- New tests do not introduce an adapter-owned result schema, human-output parser, or persistent scratch outside the existing contract.
- The full Buck-backed suite and repository-level action inspection pass.

## Non-goals

This task does not remove, retire, or consolidate existing tests. It does not add stable abort, cancellation, retry, group, remote-execution, or generated-output semantics that remain deferred by the roadmap.
