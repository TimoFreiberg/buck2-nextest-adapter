#!/bin/sh
set -eu

root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-$(dirname "$0")}
[ -f "$root/README.md" ] || root=$(cd "$(dirname "$0")/.." && pwd)
readme=$root/README.md
baseline=$root/docs/baseline-and-manifest.md
roadmap=$root/docs/nextest-buck2-roadmap.md
[ -f "$root/baseline-and-manifest.md" ] && baseline=$root/baseline-and-manifest.md
[ -f "$root/nextest-buck2-roadmap.md" ] && roadmap=$root/nextest-buck2-roadmap.md
grep -F '## Buck2-built artifact handoff' "$readme" >/dev/null
grep -F '## Baseline and manifest contract' "$readme" >/dev/null
grep -Fi 'experimental' "$baseline" >/dev/null
grep -Fi 'pre-release' "$baseline" >/dev/null
grep -Fi 'one static' "$baseline" >/dev/null
grep -Fi 'manifest-driven' "$baseline" >/dev/null
grep -F -- '--success-output' "$readme" >/dev/null
grep -F -- '--failure-output' "$readme" >/dev/null
grep -Fi 'JUnit XML' "$baseline" >/dev/null
grep -Fi 'full status' "$baseline" >/dev/null
grep -Fi 'future incompatible' "$readme" >/dev/null
grep -Fi 'retries, timeouts' "$readme" >/dev/null
grep -Fi 'groups' "$readme" >/dev/null
grep -Fi 'cancellation redesign' "$readme" >/dev/null
grep -F '## Current position' "$roadmap" >/dev/null
grep -F 'Buck2-built artifact handoff' "$roadmap" >/dev/null
grep -Fi 'remote execution remain' "$roadmap" >/dev/null
printf '%s\n' 'documentation smoke: passed'
