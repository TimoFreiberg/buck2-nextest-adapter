#!/bin/sh
set -eu

output=${1:?declared JUnit output argument is required}
[ -f "$output" ]
[ -z "${BUCK2_NEXTEST_DISPATCH_LOG:-}" ] || exit 1
toolchain_buck=${BUCK_PROJECT_ROOT:-.}/toolchains/BUCK
[ -f "$toolchain_buck" ] || toolchain_buck=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}/toolchains/BUCK
grep -F "local tool inputs" "$toolchain_buck"
python3 - "$output" <<'PY'
import sys
import xml.etree.ElementTree as ET
assert [x.attrib["name"] for x in ET.parse(sys.argv[1]).getroot().iter("testcase")] == ["pass_case"]
PY
printf '%s\n' "declared JUnit toolchain passed: local-only"
