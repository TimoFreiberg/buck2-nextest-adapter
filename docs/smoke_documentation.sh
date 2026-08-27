#!/bin/sh
set -eu

root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-$(dirname "$0")}
[ -f "$root/README.md" ] || root=$(cd "$(dirname "$0")/.." && pwd)
readme=$root/README.md
justfile=$root/Justfile
baseline=$root/docs/baseline-and-manifest.md
roadmap=$root/docs/nextest-buck2-roadmap.md
follow_up=$root/docs/test-coverage-follow-up.md
roadmap_follow_ups=$root/docs/roadmap-follow-ups.md
[ -f "$root/baseline-and-manifest.md" ] && baseline=$root/baseline-and-manifest.md
[ -f "$root/nextest-buck2-roadmap.md" ] && roadmap=$root/nextest-buck2-roadmap.md
[ -f "$root/roadmap-follow-ups.md" ] && roadmap_follow_ups=$root/roadmap-follow-ups.md

grep -F '## Canonical invocation' "$readme" >/dev/null
grep -F '`nextest_buck_test` is the supported fresh-test surface' "$readme" >/dev/null
grep -F '`buck-artifact` remains the separate build-action adapter mode' "$readme" >/dev/null
grep -F -- '--junit-report PATH' "$readme" >/dev/null
for control in profile filter no-tests report-skipped timeout-seconds; do grep -F -- "$control" "$readme" "$baseline" "$roadmap" >/dev/null; done
grep -F 'copies the nextest bytes unchanged' "$readme" >/dev/null
grep -F 'Rust-only' "$readme" >/dev/null
grep -F 'no Python' "$readme" >/dev/null
grep -F 'no-tests' "$readme" >/dev/null
grep -F 'returns `100`' "$readme" >/dev/null
grep -F 'signal-derived status' "$readme" >/dev/null
grep -F 'observation/regeneration inputs only' "$readme" >/dev/null
grep -F 'nextest_buck_artifact_junit' "$readme" "$baseline" "$roadmap" >/dev/null
grep -F 'local-preferred' "$readme" "$baseline" "$roadmap" >/dev/null
grep -F -- '--remote-only' "$readme" "$roadmap" >/dev/null
grep -F 'BUCK2_NEXTEST_RE_CONFIG_FILE' "$readme" "$roadmap" >/dev/null
grep -F 'BUCK2_NEXTEST_RE_EXECUTION_PLATFORM_LABEL' "$readme" "$roadmap" >/dev/null
grep -F 'remote gate' "$baseline" >/dev/null
grep -F 'blocked-no-backend' "$readme" "$roadmap" >/dev/null
grep -F 'observability-gap' "$readme" "$roadmap" >/dev/null
grep -F 'allow_cache_upload = False' "$root/nextest.bzl" >/dev/null
grep -F 'successful output materialization' "$readme" >/dev/null
grep -F 'worker-side execution' "$readme" "$baseline" "$roadmap" >/dev/null
grep -F 'nextest_buck_artifact_remote_selftest' "$readme" >/dev/null
! grep -F 'local-only' "$readme" "$roadmap" >/dev/null
grep -F 'BUCK_SCRATCH_PATH' "$readme" "$baseline" >/dev/null
grep -F '`just ci` runs the relocated artifact check and the real declared nextest' "$readme" >/dev/null
grep -F 'nextest_buck_test' "$readme" "$baseline" "$justfile" >/dev/null
grep -F 'ExternalRunnerTestInfo' "$readme" "$baseline" >/dev/null
grep -F 'b2n1:' "$baseline" >/dev/null
grep -F 'process-inspection prerequisites fail' "$readme" >/dev/null
grep -F 'production check as repository-level checks' "$readme" >/dev/null
 grep -F 'relocated/sanitized' "$readme" "$baseline" "$roadmap" >/dev/null
grep -F 'observability gap' "$readme" "$baseline" >/dev/null
grep -F 'buck clean' "$readme" "$baseline" >/dev/null
grep -F 'caller-owned' "$baseline" >/dev/null
grep -F 'test.v2_test_executor' "$readme" "$baseline" "$roadmap" >/dev/null
grep -F '1560aca2002865cd73d7cafb22c705cfb640b2bc' "$readme" "$baseline" "$roadmap" >/dev/null
grep -F 'Rust 1.88' "$readme" "$roadmap" >/dev/null
grep -F 'BUCK2_NEXTEST_JUNIT_DIR' "$readme" "$baseline" "$roadmap" >/dev/null
grep -F 'INFRA_FAILURE' "$readme" "$baseline" "$roadmap" >/dev/null
grep -F 'fresh caller-owned' "$readme" "$roadmap" >/dev/null
grep -F 'fixture XML' "$readme" "$roadmap" >/dev/null
grep -F 'does not run cargo-nextest' "$baseline" >/dev/null
grep -F 'DefaultInfo' "$readme" "$baseline" >/dev/null
grep -F 'RunInfo' "$readme" "$baseline" >/dev/null
grep -F 'local convenience' "$readme" "$baseline" >/dev/null

grep -Fi 'experimental' "$baseline" >/dev/null
grep -Fi 'pre-release' "$baseline" >/dev/null
grep -F '{"name": "ignored_case", "ignored": true}' "$baseline" >/dev/null
grep -F 'test count `2`' "$baseline" >/dev/null
grep -F 'count `4`' "$baseline" >/dev/null
grep -F 'timeout_case' "$baseline" >/dev/null
grep -F 'slow-timeout = { period = "1s", terminate-after = 1, grace-period = "0s" }' "$baseline" >/dev/null
grep -F 'no timeout-specific marker' "$baseline" >/dev/null
grep -F 'mode-0600 same-directory temporary' "$baseline" >/dev/null
grep -F 'raw nextest status=<status>' "$baseline" >/dev/null

grep -F '## Current position' "$roadmap" >/dev/null
grep -F 'schema-v2 production slice is implemented' "$roadmap" >/dev/null
grep -F 'five attrs' "$roadmap" >/dev/null
grep -F 'default-*' "$readme" "$baseline" >/dev/null
grep -F 'fixed-name `junit.xml`' "$baseline" "$roadmap" >/dev/null
grep -F 'successful-build artifact only' "$readme" "$baseline" >/dev/null
grep -F 'failed declared outputs are not a supported' "$readme" "$baseline" >/dev/null
grep -F 'ordinary failed-action diagnostics' "$readme" "$baseline" "$roadmap" >/dev/null
grep -F 'caller-supplied `--junit-report`' "$readme" "$baseline" "$roadmap" >/dev/null
grep -F 'outer `buck2 test` capture' "$baseline" >/dev/null

grep -F 'The bounded matrix covers pass' "$roadmap" >/dev/null
grep -F 'filtered-out,' "$roadmap" >/dev/null
legacy_switch=$(printf '%s%s' -- -scenario)
! grep -F -- "$legacy_switch" "$readme" "$baseline" "$roadmap" >/dev/null
grep -F 'no timeout-specific marker' "$roadmap" >/dev/null
grep -F 'outer cancellation and descendant' "$roadmap" >/dev/null
grep -F '## Remaining roadmap work' "$roadmap" >/dev/null
grep -F 'The schema-v2 production vertical slice above is the current-state record' "$roadmap" >/dev/null
grep -F 'successful dispatch path' "$follow_up" >/dev/null
grep -F 'no-tests = auto' "$follow_up" >/dev/null
grep -F 'disabled timeout configuration' "$follow_up" >/dev/null
grep -F 'build-mode argument validation' "$follow_up" >/dev/null
grep -F 'report temporary-file permissions' "$follow_up" >/dev/null
grep -F 'process-group prerequisite' "$follow_up" >/dev/null
grep -F 'action graph wiring' "$follow_up" >/dev/null
grep -F 'DefaultInfo' "$follow_up" >/dev/null
grep -F 'relocated/sanitized declared-input scenario is required repository-level CI coverage' "$follow_up" >/dev/null

! grep -F 'adapter.sh cargo-fixture' "$readme" "$baseline" "$roadmap"
! grep -F '//:nextest_spike' "$readme" "$baseline" "$roadmap"
! grep -F 'JUnit XML is a deferred reporting surface' "$readme" "$baseline" "$roadmap"
! grep -F 'failed-output retrieval is supported' "$readme" "$baseline" "$roadmap"
! grep -F 'remote CI is mandatory' "$readme" "$roadmap"
! grep -F 'fake RE service' "$readme" "$roadmap"
! grep -F 'vendor-specific execution platform' "$readme" "$roadmap"
! grep -F 'endpoint defaults' "$readme" "$roadmap"
! grep -F 'Start Phase 5 with a bounded reporting' "$roadmap"

# The new sequence is executable documentation: every roadmap anchor resolves,
# required evidence and boundaries remain explicit, and no follow-up is claimed
# complete before its future acceptance check exists.
for anchor in realistic-rust-runtime-closure core-nextest-value simplify-compatibility reassess-and-resume-remote; do
    grep -F "roadmap-follow-ups.md#$anchor" "$roadmap" >/dev/null
    grep -F "<a id=\"$anchor\"></a>" "$roadmap_follow_ups" >/dev/null
done
[ "$(grep -c '^<a id=' "$roadmap_follow_ups")" -eq 9 ]
! grep -Ei '^([0-9]+\.|###).*follow-up.*(complete|implemented)' "$roadmap_follow_ups" >/dev/null

for evidence in 'nextest.bzl:206-272' 'adapter/src/bin/nextest_buck_artifact.rs' 'adapter/src/manifest_v1.rs' 'tools/nextest_cargo_nextest_v1.py:28-56' 'docs/nextest-buck2-roadmap.md'; do
    grep -F "$evidence" "$roadmap_follow_ups" >/dev/null
done
for heading in '## Architectural invariants' '## 1. Freeze further remote-readiness expansion temporarily' '## 2. Define the primary Buck test surface' '## 3. Generalize the artifact/runtime contract' '## 4. Implement a Rust runner' '## 5. Prove real nextest through the declared production path' '## 6. Support a realistic Buck Rust runtime closure' '## 7. Prove the core nextest value proposition' '## 8. Simplify the compatibility layer and consumer setup' '## 9. Reassess integration and resume remote validation' '### Feature-to-test matrix' '## Quick-cleanup assertion matrix' '## Prioritization'; do
    grep -F "$heading" "$roadmap_follow_ups" >/dev/null
done
for invariant in 'Buck remains authoritative for build artifacts' 'Nextest remains authoritative for test discovery' 'must not invoke Cargo or rustc' 'No source-tree or arbitrary unmanaged `buck-out` writes' 'Fresh test execution must use Buck' 'Preserve exact nextest JUnit bytes' 'Do not' 'Process-tree cleanup, cancellation, and no-orphan behavior' 'Consumer setup should become simpler'; do
    grep -F "$invariant" "$roadmap_follow_ups" >/dev/null
done
for group in '**next**' '**after the local production path**' '**deferred until evidence requires it**'; do grep -F "$group" "$roadmap_follow_ups" >/dev/null; done

# Generic semantic identity and pre-staging rejection are architectural, while
# only provider field names and collision-free encoding mechanics are deferred.
for contract in '(package identity, canonical Buck target label, binary identity)' 'configuration-independent canonical Buck owner label in cell/package/target' 'supported Buck providers' 'minimal explicit wrapper/provider' 'deterministically and reversibly' 'Display name, executable basename, and filesystem' 'exactly one executable' 'duplicate triples' 'duplicate executable association' 'multiple-executable record' 'normalization/encoding collision before staging' 'one executable associated with multiple records' 'multiple executables in one record' 'Only exact supported-provider field names and collision-free encoding mechanics are deferred' 'the sole source of test-case names for execution'; do
    grep -F "$contract" "$roadmap_follow_ups" >/dev/null
done

# The existing JUnit build action cannot change status before the complete,
# operator-approved decision record and evidence gate are present.
for gate in 'neither removes nor promotes' 'operator-approved decision record' 'owner/approver' 'selected outcome' 'real toolchain' 'statuses remain documented' 'unchanged JUnit bytes and diagnostics' 'cancellation' 'fresh-execution' 'migration/documentation consequences' 'explicit removal or support boundary' 'indefinitely ambiguous'; do
    grep -F "$gate" "$roadmap_follow_ups" >/dev/null
done

! grep -F 'Production remains `local_only = True`' "$readme" >/dev/null
grep -F 'local-preferred' "$readme" >/dev/null
grep -F 'checksum-verified HTTP archives' "$readme" >/dev/null
grep -F 'Windows is unsupported' "$readme" >/dev/null
grep -F 'cache upload disabled' "$readme" >/dev/null
grep -F 'caller-owned RE configuration' "$readme" >/dev/null
grep -F -- '--remote-only' "$readme" >/dev/null

python3 - "$roadmap_follow_ups" "$root/BUCK" "$root/Justfile" "$root" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()
buck = Path(sys.argv[2]).read_text()
just = Path(sys.argv[3]).read_text()
root_path = Path(sys.argv[4])

required_checks = {
    "buck2_nextest_real_declared_toolchain",
    "buck2_nextest_generic_multi_binary",
    "buck2_nextest_runtime_closure",
    "buck2_nextest_retry_and_process_isolation",
    "buck2_nextest_timeout_and_slowness",
    "buck2_nextest_output_capture",
    "buck2_nextest_ignored_tests",
    "buck2_nextest_group_concurrency",
    "buck2_nextest_cancellation_cleanup",
    "buck2_nextest_remote_platform_and_materialization",
}
feature = text.split("### Feature-to-test matrix", 1)[1].split("**Risks/decision triggers.**", 1)[0]
rows = [line for line in feature.splitlines() if line.startswith("| ") and "Named future check" not in line and not line.startswith("|---")]
assert rows, "feature matrix has no rows"
for row in rows:
    cells = [cell.strip() for cell in row.strip("|").split("|")]
    assert len(cells) == 4, f"malformed feature row: {row}"
    assert cells[2] and ("Fails " in cells[2] or "Fails unless" in cells[2] or "Fail-closed probe" in cells[2]), f"non-regression-sensitive assertion: {row}"
    assert cells[3] == "Uses the production Buck test rule and real declared nextest toolchain.", f"missing production constraint: {row}"
for check in required_checks:
    assert any(f"`{check}`" in row for row in rows), f"missing future check {check}"

matrix = text.split("## Quick-cleanup assertion matrix", 1)[1].split("## Prioritization", 1)[0]
rows = [line for line in matrix.splitlines() if line.startswith("| `")]
expected = {
    "nextest_buck_artifact_rule_contract.sh": 12,
    "scenario_removed.sh": 3,
    "legacy_path_absent.sh": 7,
}
for script, count in expected.items():
    script_rows = [line for line in rows if line.startswith(f"| `{script}` |")]
    assert len(script_rows) == count, (script, len(script_rows), count)
    dispositions = {re.findall(r"\| `(retain|delete)` \|", line)[0] for line in script_rows}
    assert len(dispositions) == 1, f"mixed script disposition: {script}"
    disposition = dispositions.pop()
    target = script.removesuffix(".sh")
    registered = f'name = "{target}"' in buck and f"//:{target}" in just
    if disposition == "retain":
        assert registered and (root_path / script).exists(), f"retained candidate missing: {script}"
    else:
        assert not registered and not (root_path / script).exists(), f"deleted candidate remains: {script}"
for policy in "prefer_local = True", "local_only = True", "allow_cache_upload = False":
    matching = [line for line in rows if f"'{policy}'" in line]
    assert len(matching) == 1 and "| `retain` |" in matching[0], f"action-policy disposition missing: {policy}"
PY

printf '%s\n' 'documentation smoke: passed'
