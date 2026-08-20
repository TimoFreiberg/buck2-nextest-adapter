#!/bin/sh
set -eu
project=${BUCK_PROJECT_ROOT:-$(pwd -P)}
buck=${BUCK2:-buck2}
run_root=$(mktemp -d "${TMPDIR:-/tmp}/nextest-buck-junit-cache.XXXXXX")
trap 'rm -rf "$run_root"' EXIT

build_one() {
    isolation=$1
    tmp=$2
    report=$3
    mkdir -p "$tmp"
    TMPDIR="$tmp" "$buck" --isolation-dir "$isolation" build //:nextest_buck_artifact_junit --show-output >"$report"
    output=$(awk '{print $2}' "$report" | tail -1)
    [ -f "$output" ] && [ ! -L "$output" ]
    python3 - "$output" <<'PY'
import sys
import xml.etree.ElementTree as ET
assert [x.attrib["name"] for x in ET.parse(sys.argv[1]).getroot().iter("testcase")] == ["pass_case"]
PY
    printf '%s\n' "$output"
}

first_event_log="$run_root/first-event-log.json-lines"
second_event_log="$run_root/second-event-log.json-lines"
out_a1=$(build_one "nextest-buck-junit-cache-a-$$" "$run_root/a1" "$run_root/a1.out")
cp "$out_a1" "$run_root/a1.xml"
out_a2=$(build_one "nextest-buck-junit-cache-a-$$" "$run_root/a2" "$run_root/a2.out")
cp "$out_a2" "$run_root/a2.xml"
cmp -s "$run_root/a1.xml" "$run_root/a2.xml"
out_b=$(build_one "nextest-buck-junit-cache-b-$$" "$run_root/b" "$run_root/b.out")
cmp -s "$run_root/a1.xml" "$out_b"

if "$buck" log --help 2>&1 | grep -F 'what-ran' >/dev/null; then
    TMPDIR="$run_root" "$buck" --isolation-dir "nextest-buck-junit-cache-a-$$" log what-ran --format json >"$run_root/what-ran.json" 2>&1 || true
    printf '%s\n' 'nextest JUnit cache check: documented what-ran surface detected; cache-hit rendering is not parsed because its schema is not stable here'
else
    printf '%s\n' 'nextest JUnit cache check: execution-observability gap; verified deterministic byte-identical same-state and fresh-state output only'
fi
if [ -d "$project/buck-out" ]; then
    ! find "$project/buck-out" -type d -name 'buck2-nextest-buck-artifact.*' -print | grep .
    ! find "$project/buck-out" -type d \( -name .nextest -o -path '*/target/nextest' \) -print | grep .
fi
