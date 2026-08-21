#!/bin/sh
set -eu
buck=${BUCK2:-buck2}
run_root=$(mktemp -d "${TMPDIR:-/tmp}/nextest-materialization.XXXXXX")
trap 'rm -rf "$run_root"' EXIT
isolation="nextest-materialization-$$"
events="$run_root/events.jsonl"
help=$($buck build --help 2>&1 || true)
if ! printf '%s\n' "$help" | grep -F -- '--event-log' >/dev/null; then
    printf '%s\n' 'materialization=observability-gap reason=event-log-capability-unavailable'
    exit 0
fi
set +e
"$buck" --isolation-dir "$isolation" build --event-log "$events" //:nextest_buck_artifact_junit >"$run_root/build.out" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] || { cat "$run_root/build.out" >&2; exit 1; }
if ! what=$($buck --isolation-dir "$isolation" log what-materialized --format json "$events" 2>"$run_root/what.err"); then
    printf '%s\n' 'materialization=observability-gap reason=what-materialized-parse-unavailable'
    exit 0
fi
if ! printf '%s\n' "$what" | python3 -c 'import json, sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    printf '%s\n' 'materialization=observability-gap reason=what-materialized-json-unparseable'
    exit 0
fi
printf '%s\n' 'materialization=observed selected-paths-only'
printf '%s\n' 'materialization note: no cache-hit, content-digest, or complete-input-enumeration claim'
