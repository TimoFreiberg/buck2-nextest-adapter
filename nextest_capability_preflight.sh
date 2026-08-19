#!/bin/sh
set -eu
out=${1:-capability-preflight.txt}
command -v cargo >/dev/null 2>&1
help=$(cargo nextest run --help 2>&1)
for flag in --filterset --profile --no-tests; do
    printf '%s\n' "$help" | grep -F -- "$flag" >/dev/null
 done
[ -n "${CARGO_NEXTTEST_VERSION:-}" ] || cargo nextest --version >/dev/null
printf '%s\n' 'report-skipped = "ignored" and slow-timeout configuration are adapter-generated and covered by captured profile tests' >"$out"
printf '%s\n' 'nextest capability preflight: passed'
