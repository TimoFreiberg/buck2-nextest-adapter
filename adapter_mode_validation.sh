#!/bin/sh
set -eu
resource_root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
adapter=$resource_root/adapter.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
run_invalid() {
    name=$1
    shift
    : >"$tmp/$name.probe"
    : >"$tmp/$name.dispatch"
    set +e
    BUCK2_NEXTEST_PROBE_LOG="$tmp/$name.probe" BUCK2_NEXTEST_DISPATCH_LOG="$tmp/$name.dispatch" "$adapter" "$@" >"$tmp/$name.out" 2>&1
    status=$?
    set -e
    [ "$status" -eq 2 ]
    [ ! -s "$tmp/$name.probe" ]
    [ ! -s "$tmp/$name.dispatch" ]
}
run_invalid missing-mode --scenario pass
run_invalid legacy cargo-fixture
run_invalid missing-inputs buck-artifact --scenario pass
run_invalid missing-report buck-artifact --artifact /missing --manifest /missing --validator /missing --cargo-baseline /missing --binary-baseline /missing --tests-baseline /missing
run_invalid invalid-scenario buck-artifact --scenario arbitrary
run_invalid old-option buck-artifact --manifest-path /missing
set +e
"$adapter" --help >"$tmp/help.out" 2>&1
help_status=$?
set -e
[ "$help_status" -eq 0 ]
grep -F -- '--scenario pass|fail|ignored|filtered|no-tests|timeout' "$tmp/help.out"
grep -F 'required mode is buck-artifact' "$tmp/missing-mode.out"
grep -F 'unknown option: cargo-fixture' "$tmp/legacy.out"
grep -F 'invalid scenario' "$tmp/invalid-scenario.out"
grep -F 'unknown option: --manifest-path' "$tmp/old-option.out"
printf '%s\n' 'adapter mode validation: passed'
