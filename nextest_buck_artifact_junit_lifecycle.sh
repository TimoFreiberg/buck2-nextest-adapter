#!/bin/sh
set -eu

project=${BUCK_PROJECT_ROOT:-$(pwd -P)}
output=${1:?declared JUnit output argument is required}
[ -f "$output" ]
first_digest=$(shasum -a 256 "$output" | awk '{print $1}')
second_digest=$(shasum -a 256 "$output" | awk '{print $1}')
[ "$first_digest" = "$second_digest" ]
! find "$project" -maxdepth 1 -type f -name 'junit.xml' -print | grep .
! find "$project/buck-out" -maxdepth 2 -type d -name 'buck2-nextest-buck-artifact.*' -print | grep .
python3 - "$output" <<'PY'
import sys
import xml.etree.ElementTree as ET
assert [x.attrib["name"] for x in ET.parse(sys.argv[1]).getroot().iter("testcase")] == ["pass_case"]
PY
printf '%s\n' 'declared JUnit lifecycle: passed'
