#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
out=$(mktemp)
trap 'rm -f "$out"' EXIT
set +e
"$root/adapter.sh" cargo-fixture --manifest-path "$root/fixture/Cargo.toml" --scenario fail >"$out" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
grep -F 'buck2-nextest-adapter: mode=cargo-fixture scenario=fail' "$out"
grep -F -- '--locked --filterset test(=fail_case)' "$out"
grep -F 'buck2-nextest-fixture: fail-test' "$out"
printf '%s\n' 'legacy expected failure: passed'
