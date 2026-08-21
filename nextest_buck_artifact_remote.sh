#!/bin/sh
set -eu

project=${BUCK_PROJECT_ROOT:-$(pwd -P)}
buck=${BUCK2:-buck2}
config=${BUCK2_NEXTEST_RE_CONFIG_FILE:-}
platform=${BUCK2_NEXTEST_RE_EXECUTION_PLATFORM_LABEL:-}
target='//:nextest_buck_artifact_junit'
normalized_target='root//:nextest_buck_artifact_junit'
category='^nextest_buck_artifact_junit$'

if [ -z "$config" ]; then
    printf '%s\n' 'remote-gate=blocked-no-backend reason=BUCK2_NEXTEST_RE_CONFIG_FILE-not-supplied'
    exit 0
fi
if [ -z "$platform" ]; then
    printf '%s\n' 'remote-gate=invalid-input reason=BUCK2_NEXTEST_RE_EXECUTION_PLATFORM_LABEL-required-with-config'
    exit 2
fi
if [ ! -f "$config" ] || [ -L "$config" ]; then
    printf '%s\n' 'remote-gate=invalid-input reason=config-must-be-a-regular-file'
    exit 2
fi
case "$platform" in
    *[!A-Za-z0-9_/:.-]*|'')
        printf '%s\n' 'remote-gate=invalid-input reason=execution-platform-label-invalid'
        exit 2
        ;;
esac

umask 077
run_root=$(mktemp -d "${TMPDIR:-/tmp}/nextest-remote-gate.XXXXXX")
isolation="nextest-remote-gate-$$_$(date +%s)"
events="$run_root/events.json-lines"
cleanup_status=0
child_pid=
child_pgid=
child_status=0
interrupted=0

cleanup() {
    status=$?
    if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
        if [ -n "$child_pgid" ]; then kill -TERM -- "-$child_pgid" 2>/dev/null || true; else kill -TERM "$child_pid" 2>/dev/null || true; fi
        deadline=$((SECONDS + 5))
        while kill -0 "$child_pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
            sleep 0.1
        done
        if kill -0 "$child_pid" 2>/dev/null; then
            if [ -n "$child_pgid" ]; then kill -KILL -- "-$child_pgid" 2>/dev/null || true; else kill -KILL "$child_pid" 2>/dev/null || true; fi
        fi
        wait "$child_pid" 2>/dev/null || true
    fi
    rm -rf "$run_root" || cleanup_status=1
    if [ "$cleanup_status" -ne 0 ] && [ "$status" -eq 0 ]; then status=$cleanup_status; fi
    exit "$status"
}
trap cleanup EXIT

on_signal() {
    interrupted=1
    if [ -n "$child_pid" ]; then
        if [ -n "$child_pgid" ]; then kill -TERM -- "-$child_pgid" 2>/dev/null || true; else kill -TERM "$child_pid" 2>/dev/null || true; fi
    fi
}
trap on_signal INT TERM HUP

fail_gap() {
    printf 'remote-gate=observability-gap reason=%s\n' "$1"
    exit 3
}
fail_configured() {
    printf 'remote-gate=failed reason=%s\n' "$1"
    exit 1
}

help="$run_root/help.txt"
if ! "$buck" --config-file "$config" --help >"$help" 2>/dev/null; then fail_gap buck-help-unavailable; fi
if ! "$buck" --config-file "$config" build --help >"$run_root/build-help.txt" 2>/dev/null; then fail_gap build-help-unavailable; fi
cat "$help" "$run_root/build-help.txt" >"$run_root/all-help.txt"
for capability in --remote-only --no-remote-cache --isolation-dir --event-log; do
    grep -F -- "$capability" "$run_root/all-help.txt" >/dev/null || fail_gap "capability-$capability-unavailable"
done
grep -F -- '--show-output' "$run_root/build-help.txt" >/dev/null || fail_gap capability-show-output-unavailable
if ! "$buck" --config-file "$config" log what-ran --help >"$run_root/what-ran-help.txt" 2>/dev/null; then fail_gap what-ran-help-unavailable; fi
grep -F -- '--emit-cache-queries' "$run_root/what-ran-help.txt" >/dev/null || fail_gap capability-cache-query-unavailable
grep -F -- '--filter-category' "$run_root/what-ran-help.txt" >/dev/null || fail_gap capability-category-filter-unavailable
if ! "$buck" --config-file "$config" log what-materialized --help >"$run_root/materialized-help.txt" 2>/dev/null; then fail_gap what-materialized-help-unavailable; fi
grep -F -- '--format' "$run_root/materialized-help.txt" >/dev/null || fail_gap capability-materialization-format-unavailable

if ! "$buck" --config-file "$config" --isolation-dir "$isolation" audit execution-platform-resolution "$target" >"$run_root/platform.txt" 2>/dev/null; then
    fail_configured platform-resolution-failed
fi
set +e
python3 - "$run_root/platform.txt" "$platform" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read().splitlines()
expected = sys.argv[2]
records = [line for line in text if line.strip()]
if len(records) != 1:
    raise SystemExit("platform-audit-record-count")
fields = dict(item.split("=", 1) for item in records[0].split("\t") if "=" in item)
if fields.get("platform") != expected:
    raise SystemExit("platform-audit-label-mismatch")
if fields.get("remote_enabled") != "True" or fields.get("local_enabled") != "False":
    raise SystemExit("platform-audit-not-remote-only")
if fields.get("command_executor") != "buck2-re":
    raise SystemExit("platform-audit-executor-unrecognized")
PY
platform_status=$?
set -e
if [ "$platform_status" -ne 0 ]; then
    fail_gap platform-audit-unparseable
fi

before="$run_root/before-scratch"
after="$run_root/after-scratch"
if [ -d "$project/buck-out" ]; then
    find "$project/buck-out" -type d \( -name 'buck2-nextest-buck-artifact.*' -o -name .nextest -o -path '*/target/nextest' \) -print | sort >"$before"
else
    : >"$before"
fi
build_out="$run_root/build.out"
set +e
if command -v setsid >/dev/null 2>&1; then
    setsid "$buck" --config-file "$config" --isolation-dir "$isolation" --remote-only --no-remote-cache build --show-output --event-log "$events" "$target" >"$build_out" 2>/dev/null &
else
    "$buck" --config-file "$config" --isolation-dir "$isolation" --remote-only --no-remote-cache build --show-output --event-log "$events" "$target" >"$build_out" 2>/dev/null &
fi
child_pid=$!
child_pgid=$child_pid
wait "$child_pid"
child_status=$?
set -e
if [ "$interrupted" -ne 0 ]; then exit 130; fi
[ "$child_status" -eq 0 ] || fail_configured build-failed
[ -s "$events" ] || fail_gap event-log-missing

output=$(awk -v target="$target" '$1 == target { print $2 }' "$build_out" | tail -n 1)
[ -n "$output" ] || fail_configured declared-output-not-reported
case "$output" in
    /*) output_path=$output ;;
    *) output_path="$project/$output" ;;
esac
output_path=$(python3 - "$output_path" <<'PY'
import os, sys
print(os.path.abspath(sys.argv[1]))
PY
)
if ! python3 - "$output_path" "$project/buck-out" <<'PY'
import os
import sys
path = os.path.realpath(sys.argv[1])
root = os.path.realpath(sys.argv[2])
if os.path.commonpath([path, root]) != root or not path.endswith("/junit.xml"):
    raise SystemExit(1)
PY
then
    printf '%s\n' 'remote-gate=failed reason=declared-output-outside-buck-out'
    exit 1
fi
[ -f "$output_path" ] && [ ! -L "$output_path" ] || fail_configured declared-output-not-materialized
python3 - "$output_path" <<'PY' || fail_configured junit-invalid
import sys
import xml.etree.ElementTree as ET
cases = list(ET.parse(sys.argv[1]).getroot().iter("testcase"))
if [case.attrib.get("name") for case in cases] != ["pass_case"]:
    raise SystemExit(1)
PY

if [ -d "$project/buck-out" ]; then
    find "$project/buck-out" -type d \( -name 'buck2-nextest-buck-artifact.*' -o -name .nextest -o -path '*/target/nextest' \) -print | sort >"$after"
    cmp -s "$before" "$after" || fail_configured adapter-private-scratch-left-behind
fi

if ! "$buck" --config-file "$config" --isolation-dir "$isolation" log what-ran --emit-cache-queries --filter-category "$category" "$events" >"$run_root/what-ran.txt" 2>/dev/null; then
    fail_gap what-ran-unavailable
fi
python3 - "$run_root/what-ran.txt" "$normalized_target" <<'PY' || fail_gap what-ran-unparseable
import sys
rows = [line.rstrip("\n") for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
records = []
for row in rows:
    fields = row.split("\t")
    if len(fields) != 4:
        continue
    reason, identity, executor, details = fields
    if reason == "build" and "(nextest_buck_artifact_junit)" in identity:
        records.append((reason, identity, executor, details))
if len(records) != 1:
    raise SystemExit(1)
reason, identity, executor, details = records[0]
if sys.argv[2] not in identity or executor != "RE":
    raise SystemExit(1)
if any(word in (reason + " " + details).lower() for word in ("cache-hit", "materialized", "cache_only", "cache-only")):
    raise SystemExit(1)
PY

if ! "$buck" --config-file "$config" --isolation-dir "$isolation" log what-materialized --format tabulated "$events" >"$run_root/materialized.txt" 2>/dev/null; then
    fail_gap what-materialized-unavailable
fi
python3 - "$run_root/materialized.txt" "$output_path" <<'PY' || fail_configured declared-output-not-in-materialization
import sys
rows = [line.rstrip("\n") for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
matches = [row for row in rows if row.split("\t", 1)[0].endswith("/junit.xml")]
if len(matches) != 1:
    raise SystemExit(1)
fields = matches[0].split("\t")
if len(fields) != 4 or fields[1] not in {"copy", "hard-link", "reflink", "write"}:
    raise SystemExit(1)
PY
if [ "${BUCK2_NEXTEST_REMOTE_SELFTEST:-0}" = 1 ]; then
    printf 'remote-selftest=passed target=%s executor=RE materialized=%s\n' "$normalized_target" "$output_path"
else
    printf 'remote-gate=passed target=%s executor=RE materialized=%s\n' "$normalized_target" "$output_path"
    printf '%s\n' 'remote-gate note: Buck observed/submitted this whole action to its RE executor; worker-side execution and RE-service deduplication are not attested. Cache, cancellation, failed-output retrieval, and per-test delegation remain deferred'
fi
exit 0
