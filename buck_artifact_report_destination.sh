#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
subcase=$1
shift
artifact=$1
manifest=$2
validator=$3
cargo_baseline=$4
binary_baseline=$5
tests_baseline=$6
tmp=$(mktemp -d "./.buck2-nextest-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
case "$subcase" in
    pre-dispatch)
        : >"$tmp/probe"
        : >"$tmp/dispatch"
        mkdir "$tmp/destination-directory"
        ln -s "$tmp/target" "$tmp/destination-symlink"
        for destination in "$tmp/destination-directory" "$tmp/destination-symlink" "$tmp/missing-parent/report.xml"; do
            set +e
            BUCK2_NEXTEST_PROBE_LOG="$tmp/probe" BUCK2_NEXTEST_DISPATCH_LOG="$tmp/dispatch" "$root/adapter.sh" buck-artifact --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --junit-report "$destination" --profile ci --filter 'test(=pass_case)' --no-tests auto --report-skipped default --timeout-seconds 0 >"$tmp/out" 2>&1
            status=$?
            set -e
            [ "$status" -eq 2 ]
            [ ! -s "$tmp/probe" ] && [ ! -s "$tmp/dispatch" ]
        done
        mkdir "$tmp/path with spaces"
        destination="$tmp/path with spaces/report.xml"
        printf old >"$destination"
        BUCK2_NEXTEST_EXPORT_DESTINATION="$destination" BUCK2_NEXTEST_EXPORT_FAULT_ACTION=capture "$root/buck_artifact_export_fault.sh" pass "$root/adapter.sh" "$tmp/capture" buck-artifact --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" >/dev/null
        [ -s "$destination" ]
        [ "$(cat "$destination")" != old ]
        ;;
    success-export-failure)
        raw=$(BUCK2_NEXTEST_EXPORT_FAULT_ACTION=remove "$root/buck_artifact_export_fault.sh" pass "$root/adapter.sh" "$tmp/fault" buck-artifact --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline")
        [ "$raw" -eq 0 ]
        ;;
    failure-export-failure)
        raw=$(BUCK2_NEXTEST_EXPORT_FAULT_ACTION=remove "$root/buck_artifact_export_fault.sh" fail "$root/adapter.sh" "$tmp/fault" buck-artifact --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline")
        [ "$raw" -eq 100 ]
        ;;
    malformed-report)
        raw=$(BUCK2_NEXTEST_EXPORT_FAULT_ACTION=malformed "$root/buck_artifact_export_fault.sh" pass "$root/adapter.sh" "$tmp/fault" buck-artifact --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline")
        [ "$raw" -eq 0 ]
        grep -F 'not valid XML' "$tmp/fault/out" >/dev/null
        ;;
    timeout-capture)
        raw=$(BUCK2_NEXTEST_EXPORT_FAULT_ACTION=capture "$root/buck_artifact_export_fault.sh" timeout "$root/adapter.sh" "$tmp/timeout-fault" buck-artifact --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline")
        [ "$raw" -eq 100 ]
        ;;
    list-failure)
        : >"$tmp/dispatch.log"
        set +e
        BUCK2_NEXTEST_LIST_FAULT_STATUS=42 BUCK2_NEXTEST_DISPATCH_LOG="$tmp/dispatch.log" "$root/adapter.sh" buck-artifact --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --junit-report "$tmp/report.xml" --profile ci --filter 'test(=pass_case)' --no-tests auto --report-skipped default --timeout-seconds 0 >"$tmp/out" 2>&1
        status=$?
        set -e
        [ "$status" -eq 42 ]
        grep -F 'nextest list failed status=42' "$tmp/out" >/dev/null
        grep -F 'top-level cargo nextest dispatch: nextest list' "$tmp/dispatch.log" >/dev/null
        ! grep -F 'top-level cargo nextest dispatch: nextest run' "$tmp/dispatch.log" >/dev/null
        [ "$(grep -c 'cleanup=once' "$tmp/out")" -eq 1 ]
        ;;
    *) printf 'unknown report destination subcase: %s\n' "$subcase" >&2; exit 2 ;;
esac
printf 'buck artifact report destination %s: passed\n' "$subcase"
