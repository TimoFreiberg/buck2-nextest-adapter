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
run_invalid missing-mode
run_invalid legacy cargo-fixture
run_invalid missing-inputs buck-artifact
run_invalid missing-report buck-artifact --artifact /missing --manifest /missing --validator /missing --cargo-baseline /missing --binary-baseline /missing --tests-baseline /missing
run_invalid invalid-profile buck-artifact --profile ../bad
run_invalid empty-filter buck-artifact --filter ''
run_invalid invalid-no-tests buck-artifact --no-tests nope
run_invalid invalid-report-skipped buck-artifact --report-skipped nope
run_invalid invalid-timeout buck-artifact --timeout-seconds -1
run_invalid too-large-timeout buck-artifact --timeout-seconds 86401
run_invalid leading-underscore buck-artifact --profile _bad
run_invalid leading-dash buck-artifact --profile -bad
run_invalid slash-profile buck-artifact --profile bad/name
run_invalid backslash-profile buck-artifact --profile 'bad\\name'
run_invalid dot-profile buck-artifact --profile bad.name
run_invalid whitespace-profile buck-artifact --profile 'bad name'
run_invalid quote-profile buck-artifact --profile 'bad"name'
run_invalid bracket-profile buck-artifact --profile 'bad[name]'
run_invalid equals-profile buck-artifact --profile 'bad=name'
run_invalid newline-profile buck-artifact --profile "bad
name"
run_invalid old-option buck-artifact --manifest-path /missing
set +e
"$adapter" --help >"$tmp/help.out" 2>&1
help_status=$?
set -e
[ "$help_status" -eq 0 ]
for option in --profile --filter --no-tests --report-skipped --timeout-seconds; do grep -F -- "$option" "$tmp/help.out"; done
grep -F 'required mode is buck-artifact' "$tmp/missing-mode.out"
grep -F 'unknown option: cargo-fixture' "$tmp/legacy.out"
for name in leading-underscore leading-dash slash-profile backslash-profile dot-profile whitespace-profile quote-profile bracket-profile equals-profile newline-profile; do grep -F 'invalid profile' "$tmp/$name.out"; done
grep -F 'invalid profile' "$tmp/invalid-profile.out"
grep -F 'filter must be non-empty' "$tmp/empty-filter.out"
grep -F 'invalid no-tests' "$tmp/invalid-no-tests.out"
grep -F 'invalid report-skipped' "$tmp/invalid-report-skipped.out"
grep -F 'invalid timeout-seconds' "$tmp/invalid-timeout.out"
grep -F 'unknown option: --manifest-path' "$tmp/old-option.out"
printf '%s\n' 'adapter mode validation: passed'
