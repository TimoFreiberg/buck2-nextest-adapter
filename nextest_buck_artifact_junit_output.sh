#!/bin/sh
set -eu

output=${1:?declared JUnit output argument is required}
case "$output" in
    */buck-out/*/junit.xml|buck-out/*/junit.xml) ;;
    *) printf '%s\n' "declared JUnit is not under buck-out: $output" >&2; exit 1 ;;
esac
[ -f "$output" ] && [ ! -L "$output" ]
python3 - "$output" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = list(root.iter("testcase"))
assert root.tag == "testsuites"
assert len(cases) == 1 and cases[0].attrib["name"] == "pass_case"
assert not list(cases[0])
assert not list(root.iter("summary"))
assert not list(root.iter("protocol"))
PY
printf '%s\n' 'declared JUnit output: passed'
