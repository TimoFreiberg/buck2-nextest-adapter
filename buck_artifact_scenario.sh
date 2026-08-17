#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
artifact=$1
manifest=$2
validator=$3
cargo_baseline=$4
binary_baseline=$5
tests_baseline=$6
tmp=$(mktemp -d "./.buck2-nextest-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
out=$tmp/out
report=$tmp/pass-report.xml
set +e
"$root/adapter.sh" buck-artifact --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --junit-report "$report" --scenario pass >"$out" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] || { cat "$out"; exit 1; }
[ -s "$report" ]
python3 - "$report" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = root.findall('.//testcase')
names = [case.get('name') for case in cases]
assert names == ['pass_case'], names
assert [child.tag for child in cases[0] if child.tag in {'failure', 'error', 'skipped'}] == []
assert not root.findall('.//adapter-summary')
PY
grep -F 'runtime=declared content=buck2-nextest-artifact-runtime-v1' "$out"
grep -F 'cwd=work' "$out"
grep -F 'test(=pass_case)' "$out"
! grep -F 'fail-test' "$out"
[ "$(grep -c 'cleanup=once' "$out")" -eq 1 ]
private_root=$(sed -n 's/.*cleanup=once root=//p' "$out")
[ -n "$private_root" ]
[ ! -e "$private_root" ]
[ -s "$report" ]
grep -F 'digest=' "$out"
printf '%s\n' 'buck artifact scenario: passed'
