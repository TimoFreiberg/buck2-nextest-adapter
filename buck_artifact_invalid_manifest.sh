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
cp "$manifest" "$tmp/manifest.json"
python3 - "$tmp/manifest.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d['paths']['runtime_inputs'] = ['manifest.json']
json.dump(d, open(sys.argv[1], 'w'))
PY
: >"$tmp/dispatch.log"
: >"$tmp/probe.log"
set +e
BUCK2_NEXTEST_DISPATCH_LOG="$tmp/dispatch.log" BUCK2_NEXTEST_PROBE_LOG="$tmp/probe.log" "$root/adapter.sh" buck-artifact --artifact "$artifact" --manifest "$tmp/manifest.json" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --junit-report "$tmp/report.xml" --profile ci --filter 'test(=pass_case)' --no-tests auto --report-skipped default --timeout-seconds 0 >"$tmp/out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ]
[ ! -s "$tmp/dispatch.log" ]
[ ! -s "$tmp/probe.log" ]
grep -F 'runtime input conflicts with adapter-owned path' "$tmp/out"
printf '%s\n' 'invalid manifest dispatch proof: passed'
