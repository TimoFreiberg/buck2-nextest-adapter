#!/bin/sh
set -eu

root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-$(dirname "$0")}
[ -f "$root/README.md" ] || root=$(cd "$(dirname "$0")/.." && pwd)
readme=$root/README.md
baseline=$root/docs/baseline-and-manifest.md
roadmap=$root/docs/nextest-buck2-roadmap.md
follow_up=$root/docs/test-coverage-follow-up.md
[ -f "$root/baseline-and-manifest.md" ] && baseline=$root/baseline-and-manifest.md
[ -f "$root/nextest-buck2-roadmap.md" ] && roadmap=$root/nextest-buck2-roadmap.md

grep -F '## Canonical invocation' "$readme" >/dev/null
grep -F '`buck-artifact` is the only supported adapter mode' "$readme" >/dev/null
grep -F -- '--junit-report PATH' "$readme" >/dev/null
for control in profile filter no-tests report-skipped timeout-seconds; do grep -F -- "$control" "$readme" "$baseline" "$roadmap" >/dev/null; done
grep -F 'copies the nextest bytes unchanged' "$readme" >/dev/null
grep -F 'Python 3.11+' "$readme" >/dev/null
grep -F 'no-tests' "$readme" >/dev/null
grep -F 'returns `100`' "$readme" >/dev/null
grep -F 'Process interruption, abort, and cancellation have no stable adapter classification' "$readme" >/dev/null
grep -F 'observation/regeneration inputs only' "$readme" >/dev/null
grep -F 'nextest_buck_artifact_junit' "$readme" "$baseline" "$roadmap" >/dev/null
grep -F 'local-only' "$readme" "$baseline" "$roadmap" >/dev/null
grep -F 'BUCK_SCRATCH_PATH' "$readme" "$baseline" >/dev/null
grep -F 'relocated/sanitized' "$readme" "$baseline" "$roadmap" >/dev/null
grep -F 'observability gap' "$readme" "$baseline" >/dev/null
grep -F 'buck clean' "$readme" "$baseline" >/dev/null
grep -F 'caller-owned' "$baseline" >/dev/null
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
grep -F 'first bounded Phase 5 milestone is complete' "$roadmap" >/dev/null
grep -F 'five attrs' "$roadmap" >/dev/null
grep -F 'default-*' "$readme" "$baseline" >/dev/null
grep -F 'fixed-name `junit.xml`' "$baseline" "$roadmap" >/dev/null
grep -F 'successful-build artifact only' "$readme" "$baseline" >/dev/null
grep -F 'failed declared outputs are not a supported' "$readme" "$baseline" >/dev/null
grep -F 'ordinary failed-action diagnostics' "$readme" "$baseline" "$roadmap" >/dev/null
grep -F 'caller-supplied `--junit-report`' "$readme" "$baseline" "$roadmap" >/dev/null
grep -F 'outer `buck2 test` capture' "$baseline" >/dev/null

grep -F 'strict failed-run semantics slice is complete' "$roadmap" >/dev/null
grep -F 'filtered-out absence' "$roadmap" >/dev/null
legacy_switch=$(printf '%s%s' -- -scenario)
! grep -F -- "$legacy_switch" "$readme" "$baseline" "$roadmap" >/dev/null
grep -F 'no timeout-specific marker' "$roadmap" >/dev/null
grep -F 'no stable dedicated mapping' "$roadmap" >/dev/null
grep -F 'Keep the completed JUnit/status boundary stable' "$roadmap" >/dev/null
grep -F 'successful dispatch path' "$follow_up" >/dev/null
grep -F 'no-tests = auto' "$follow_up" >/dev/null
grep -F 'disabled timeout configuration' "$follow_up" >/dev/null
grep -F 'build-mode argument validation' "$follow_up" >/dev/null
grep -F 'report temporary-file permissions' "$follow_up" >/dev/null
grep -F 'process-group prerequisite' "$follow_up" >/dev/null
grep -F 'action graph wiring' "$follow_up" >/dev/null
grep -F 'DefaultInfo' "$follow_up" >/dev/null
grep -F 'relocated/sanitized declared-input scenario is available as a repository-level check' "$follow_up" >/dev/null

! grep -F 'adapter.sh cargo-fixture' "$readme" "$baseline" "$roadmap"
! grep -F '//:nextest_spike' "$readme" "$baseline" "$roadmap"
! grep -F 'JUnit XML is a deferred reporting surface' "$readme" "$baseline" "$roadmap"
! grep -F 'failed-output retrieval is supported' "$readme" "$baseline" "$roadmap"
! grep -F 'Start Phase 5 with a bounded reporting' "$roadmap"
printf '%s\n' 'documentation smoke: passed'
