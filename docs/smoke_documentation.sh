#!/bin/sh
set -eu

grep -F '## Buck2-built artifact handoff' README.md >/dev/null
grep -F '## Baseline and manifest contract' README.md >/dev/null
grep -Fi 'retries, timeouts' README.md >/dev/null
grep -Fi 'groups, JUnit/status mapping' README.md >/dev/null
grep -F '## Current position' docs/nextest-buck2-roadmap.md >/dev/null
grep -F 'Buck2-built artifact handoff' docs/nextest-buck2-roadmap.md >/dev/null
grep -Fi 'remote execution remain' docs/nextest-buck2-roadmap.md >/dev/null
printf '%s\n' 'documentation smoke: passed'
