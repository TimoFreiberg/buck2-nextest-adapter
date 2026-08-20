#!/bin/sh
set -eu
project=${BUCK_PROJECT_ROOT:-$(pwd -P)}
buck=${BUCK2:-buck2}
run_root=$(mktemp -d "${TMPDIR:-/tmp}/nextest-buck-junit-key.XXXXXX")
trap 'rm -rf "$run_root"' EXIT
isolation="nextest-buck-junit-key-$$"
log="$run_root/argv.log"
marker="$run_root/marker"
for variant in v1 v2; do
    rm -f "$marker" "$log"
    : >"$log"
    TMPDIR="$run_root" BUCK2_NEXTEST_ARGV_LOG="$log" BUCK2_NEXTEST_TOOL_MARKER="$marker" \
        "$buck" --isolation-dir "$isolation-$variant" build "//:nextest_buck_artifact_junit_tool_$variant" >/dev/null
    [ -f "$marker" ]
    grep -Fx "$variant" "$marker"
    [ -s "$log" ]
    output=$(TMPDIR="$run_root" "$buck" --isolation-dir "$isolation-$variant" build "//:nextest_buck_artifact_junit_tool_$variant" --show-output | awk '{print $2}')
    [ -f "$output" ] && [ ! -L "$output" ]
    python3 - "$output" <<'PY'
import sys
import xml.etree.ElementTree as ET
assert [x.attrib["name"] for x in ET.parse(sys.argv[1]).getroot().iter("testcase")] == ["pass_case"]
PY
done
printf '%s\n' 'nextest declared tool action-key experiment: selected tool dispatch passed; stable aquery input field unavailable, so no same-owner content-key claim'
