#!/bin/sh
set -eu

project=${BUCK_PROJECT_ROOT:-$(pwd -P)}
buck=${BUCK2:-buck2}
run_root=$(mktemp -d "${TMPDIR:-/tmp}/nextest-junit-local.XXXXXX")
trap 'rm -rf "$run_root"' EXIT
isolation="nextest-junit-local-$$_$(date +%s)"
events="$run_root/events.json-lines"
help="$run_root/help.txt"
"$buck" build --help >"$help" 2>/dev/null || { printf '%s\n' 'local-check=observability-gap reason=buck-help-unavailable' >&2; exit 1; }
grep -F -- '--event-log' "$help" >/dev/null || { printf '%s\n' 'local-check=observability-gap reason=event-log-capability-unavailable' >&2; exit 1; }
set +e
"$buck" --isolation-dir "$isolation" build --show-output --event-log "$events" //:nextest_buck_artifact_junit >"$run_root/build.out" 2>&1
build_status=$?
set -e
[ "$build_status" -eq 0 ] || { printf '%s\n' 'local-check=failed reason=build-failed' >&2; cat "$run_root/build.out" >&2; exit 1; }
[ -s "$events" ] || { printf '%s\n' 'local-check=observability-gap reason=event-log-missing' >&2; exit 1; }
output=$(awk '$1 == "root//:nextest_buck_artifact_junit" || $1 == "//:nextest_buck_artifact_junit" { print $2 }' "$run_root/build.out" | tail -1)
[ -n "$output" ] || { printf '%s\n' 'local-check=failed reason=declared-output-not-reported' >&2; exit 1; }
case "$output" in /*) ;; *) output="$project/$output" ;; esac
[ -f "$output" ] && [ ! -L "$output" ]
python3 - "$output" <<'PY'
import sys
import xml.etree.ElementTree as ET
cases = list(ET.parse(sys.argv[1]).getroot().iter("testcase"))
assert [case.attrib.get("name") for case in cases] == ["pass_case"]
PY
what_help="$run_root/what-help.txt"
if ! "$buck" log what-ran --help >"$what_help" 2>/dev/null || ! grep -F -- '--filter-category' "$what_help" >/dev/null; then
    printf '%s\n' 'local-check=observability-gap reason=what-ran-category-filter-unavailable' >&2
    exit 1
fi
what="$run_root/what-ran.txt"
"$buck" --isolation-dir "$isolation" log what-ran --filter-category '^nextest_buck_artifact_junit$' "$events" >"$what" 2>/dev/null || { printf '%s\n' 'local-check=observability-gap reason=what-ran-unavailable' >&2; exit 1; }
python3 - "$what" <<'PY'
import sys
rows = [line.rstrip("\n") for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
records = []
for row in rows:
    fields = row.split("\t")
    if len(fields) == 4 and fields[0] == "build" and "(nextest_buck_artifact_junit)" in fields[1]:
        records.append(fields)
if len(records) != 1:
    raise SystemExit(2)
if records[0][2] != "local":
    raise SystemExit(3)
if "root//:nextest_buck_artifact_junit" not in records[0][1]:
    raise SystemExit(4)
PY
printf '%s\n' 'local-check=passed executor=local default-policy-only'
printf '%s\n' 'local-check note: this is not an absolute local-only guarantee under an externally configured hybrid executor'
