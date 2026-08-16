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
p = sys.argv[1]
d = json.load(open(p))
d['environment']['BUCK2_ARTIFACT_RUNTIME'] = 'mutated'
json.dump(d, open(p, 'w'))
PY
out=$tmp/out
"$root/adapter.sh" buck-artifact --artifact "$artifact" --manifest "$tmp/manifest.json" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --scenario pass >"$out" 2>&1
grep -F 'runtime=mutated content=buck2-nextest-artifact-runtime-v1' "$out"
cp "$manifest" "$tmp/invalid.json"
python3 - "$tmp/invalid.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d['paths']['runtime_inputs'] = ['undeclared/file.txt']
json.dump(d, open(sys.argv[1], 'w'))
PY
set +e
BUCK2_NEXTEST_DISPATCH_LOG="$tmp/dispatch.log" "$root/adapter.sh" buck-artifact --artifact "$artifact" --manifest "$tmp/invalid.json" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --scenario pass >"$tmp/invalid.out" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
[ ! -s "$tmp/dispatch.log" ]
grep -F 'runtime resource undeclared/file.txt does not exist in staging root' "$tmp/invalid.out"
printf '%s\n' 'buck artifact mutation: passed'
