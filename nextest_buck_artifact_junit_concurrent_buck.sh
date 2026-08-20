#!/bin/sh
set -eu
project=${BUCK_PROJECT_ROOT:-$(pwd -P)}
buck=${BUCK2:-buck2}
run_root=$(mktemp -d "${TMPDIR:-/tmp}/nextest-buck-junit-concurrent.XXXXXX")
trap 'rm -rf "$run_root"' EXIT
isolation="nextest-buck-junit-concurrent-$$"
TMPDIR="$run_root" "$buck" --isolation-dir "$isolation" build //:nextest_buck_artifact_junit //:nextest_buck_artifact_junit_custom --show-output >"$run_root/build.out"
outputs=$(awk '{print $2}' "$run_root/build.out")
count=$(printf '%s\n' "$outputs" | wc -l | tr -d ' ')
[ "$count" -eq 2 ]
first=$(printf '%s\n' "$outputs" | sed -n '1p')
second=$(printf '%s\n' "$outputs" | sed -n '2p')
[ "$first" != "$second" ]
for output in "$first" "$second"; do
    [ -f "$output" ] && [ ! -L "$output" ]
    python3 - "$output" <<'PY'
import sys
import xml.etree.ElementTree as ET
assert [x.attrib["name"] for x in ET.parse(sys.argv[1]).getroot().iter("testcase")] == ["pass_case"]
PY
done
if [ -d "$project/buck-out" ]; then
    ! find "$project/buck-out" -type d -name 'buck2-nextest-buck-artifact.*' -print | grep .
fi
printf '%s\n' 'nextest Buck concurrent actions: passed; separate-process concurrency remains environment-gated'
