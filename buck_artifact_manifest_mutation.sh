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
cp "$manifest" "$tmp/manifest.json"
python3 - "$tmp/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['environment']['BUCK2_ARTIFACT_RUNTIME'] = 'mutated'
json.dump(d, open(p, 'w'))
PY
out=$tmp/out
"$root/adapter.sh" buck-artifact --artifact "$artifact" --manifest "$tmp/manifest.json" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --junit-report "$tmp/report.xml" --scenario pass >"$out" 2>&1
grep -F 'runtime=mutated content=buck2-nextest-artifact-runtime-v1' "$out"
[ -s "$tmp/report.xml" ]
cp "$manifest" "$tmp/invalid.json"
python3 - "$tmp/invalid.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d['paths']['runtime_inputs'] = ['undeclared/file.txt']
json.dump(d, open(sys.argv[1], 'w'))
PY
: >"$tmp/dispatch.log"
: >"$tmp/probe.log"
set +e
BUCK2_NEXTEST_DISPATCH_LOG="$tmp/dispatch.log" BUCK2_NEXTEST_PROBE_LOG="$tmp/probe.log" "$root/adapter.sh" buck-artifact --artifact "$artifact" --manifest "$tmp/invalid.json" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --junit-report "$tmp/invalid-report.xml" --scenario pass >"$tmp/invalid.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ]
[ ! -s "$tmp/dispatch.log" ]
[ ! -s "$tmp/probe.log" ]
grep -F 'runtime resource undeclared/file.txt does not exist in staging root' "$tmp/invalid.out"
printf '%s\n' 'buck artifact mutation: passed'
