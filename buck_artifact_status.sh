#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
case_name=$1
shift
artifact=$1
manifest=$2
validator=$3
cargo_baseline=$4
binary_baseline=$5
tests_baseline=$6
tmp=$(mktemp -d "./.buck2-nextest-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
report=$tmp/report.xml
out=$tmp/out
set +e
"$root/adapter.sh" buck-artifact --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --junit-report "$report" --scenario "$case_name" >"$out" 2>&1
status=$?
set -e
case "$case_name" in
    ignored)
        [ "$status" -eq 0 ] || { cat "$out"; exit 1; }
        [ -s "$report" ]
        python3 - "$report" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = root.findall('.//testcase')
assert [c.get('name') for c in cases] == ['ignored_case']
assert cases[0].find('skipped') is not None
PY
        ;;
    filtered)
        [ "$status" -eq 0 ] || { cat "$out"; exit 1; }
        [ -s "$report" ]
        python3 - "$report" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = root.findall('.//testcase')
assert [c.get('name') for c in cases] == ['pass_case']
assert cases[0].find('failure') is None
assert cases[0].find('skipped') is None
PY
        ;;
    no-tests)
        [ "$status" -eq 4 ] || { cat "$out"; printf 'expected status 4, got %s\n' "$status" >&2; exit 1; }
        if [ -e "$report" ]; then
            python3 - "$report" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
assert root.findall('.//testcase') == []
PY
        fi
        ;;
    *) printf 'unknown status subcase: %s\n' "$case_name" >&2; exit 2 ;;
esac
[ "$(grep -c 'cleanup=once' "$out")" -eq 1 ]
private_root=$(sed -n 's/.*cleanup=once root=//p' "$out")
[ -n "$private_root" ] && [ ! -e "$private_root" ]
printf 'buck artifact status %s: passed\n' "$case_name"
