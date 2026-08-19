#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
artifact=$1
manifest=$2
validator=$3
cargo_baseline=$4
binary_baseline=$5
tests_baseline=$6
export BUCK2_NEXTEST_TEST_EXECUTOR=1
tmp=$(mktemp -d "./.buck2-nextest-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
out=$tmp/out
report=$tmp/failure-report.xml
set +e
"$root/adapter.sh" buck-artifact --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --junit-report "$report" --profile ci --filter 'test(=fail_case)' --no-tests auto --report-skipped default --timeout-seconds 0 >"$out" 2>&1
status=$?
set -e
[ "$status" -eq 100 ] || { cat "$out"; printf 'expected status 100, got %s\n' "$status" >&2; exit 1; }
[ -s "$report" ]
python3 - "$report" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = root.findall('.//testcase')
names = [case.get('name') for case in cases]
assert names == ['fail_case'], names
assert [child.tag for child in cases[0] if child.tag in {'failure', 'error', 'skipped'}] == ['failure']
assert not root.findall('.//adapter-summary')
PY
grep -F 'test(=fail_case)' "$out"
grep -F 'fail-test' "$out"
! grep -F 'pass-test' "$out"
[ "$(grep -c 'cleanup=once' "$out")" -eq 1 ]
private_root=$(sed -n 's/.*cleanup=once root=//p' "$out")
[ -n "$private_root" ]
[ ! -e "$private_root" ]
[ -s "$report" ]
printf '%s\n' 'buck artifact expected failure: passed'
