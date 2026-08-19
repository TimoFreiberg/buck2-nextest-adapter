#!/bin/sh
set -eu
first=${1:?default output required}
second=${2:?custom output required}
for output in "$first" "$second"; do
    case "$output" in
        */buck-out/*/junit.xml|buck-out/*/junit.xml) ;;
        *) printf 'output is not under buck-out: %s\n' "$output" >&2; exit 1 ;;
    esac
    [ -f "$output" ] && [ ! -L "$output" ]
done
[ "$first" != "$second" ]
python3 - "$first" "$second" <<'PY'
import sys
import xml.etree.ElementTree as ET
for path in sys.argv[1:]:
    cases = list(ET.parse(path).getroot().iter("testcase"))
    assert [case.attrib["name"] for case in cases] == ["pass_case"]
PY
project=${BUCK_PROJECT_ROOT:-$(pwd -P)}
[ ! -e "$project/junit.xml" ]
if [ -d "$project/buck-out" ]; then
    ! find "$project/buck-out" -type d -name 'buck2-nextest-buck-artifact.*' -print | grep .
fi
printf '%s\n' 'declared JUnit outputs: passed'
