#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
artifact=$1
manifest=$2
validator=$3
cargo_baseline=$4
binary_baseline=$5
tests_baseline=$6
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$manifest" "$tmp/manifest.json"
python3 - "$tmp/manifest.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d['paths']['runtime_inputs'] = ['manifest.json']
json.dump(d, open(sys.argv[1], 'w'))
PY
: > "$tmp/dispatch.log"
set +e
BUCK2_NEXTEST_DISPATCH_LOG="$tmp/dispatch.log" "$root/adapter.sh" buck-artifact --artifact "$artifact" --manifest "$tmp/manifest.json" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" >"$tmp/out" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
[ ! -s "$tmp/dispatch.log" ]
grep -F 'runtime input conflicts with adapter-owned path' "$tmp/out"
printf '%s\n' 'invalid manifest dispatch proof: passed'
