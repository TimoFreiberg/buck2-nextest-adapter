#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
artifact=$1
manifest=$2
validator=$3
cargo_baseline=$4
binary_baseline=$5
tests_baseline=$6
out=$(mktemp)
trap 'rm -f "$out"' EXIT
set +e
"$root/adapter.sh" buck-artifact --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --scenario fail >"$out" 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || { cat "$out"; exit 1; }
grep -F 'test(=fail_case)' "$out"
grep -F 'fail-test' "$out"
! grep -F 'pass-test' "$out"
[ "$(grep -c 'cleanup=once' "$out")" -eq 1 ]
private_root=$(sed -n 's/.*cleanup=once root=//p' "$out")
[ -n "$private_root" ]
[ ! -e "$private_root" ]
printf '%s\n' 'buck artifact expected failure: passed'
