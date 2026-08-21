#!/bin/sh
set -eu
resource_root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
adapter=$resource_root/adapter.sh
artifact=${1:-}
manifest=${2:-}
validator=${3:-}
cargo_baseline=${4:-}
binary_baseline=${5:-}
tests_baseline=${6:-}
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
run_build_invalid() {
    name=$1
    missing=$2
    shift 2
    : >"$tmp/$name.probe"
    : >"$tmp/$name.dispatch"
    set +e
    env -u BUCK2_NEXTEST_CARGO_COMMAND -u BUCK2_NEXTEST_CARGO_NEXTEST_COMMAND -u BUCK2_NEXTEST_RUNTIME_RESOURCE -u BUCK2_NEXTEST_SOURCE_DENIAL \
        BUCK2_NEXTEST_PROBE_LOG="$tmp/$name.probe" BUCK2_NEXTEST_DISPATCH_LOG="$tmp/$name.dispatch" \
        "$adapter" "$@" >"$tmp/$name.out" 2>&1
    status=$?
    set -e
    [ "$status" -eq 2 ] || { echo "subcase $name status=$status" >&2; cat "$tmp/$name.out" >&2; exit 1; }
    grep -F "build mode requires --$missing" "$tmp/$name.out" || { echo "subcase $name diagnostic mismatch" >&2; cat "$tmp/$name.out" >&2; exit 1; }
    [ ! -s "$tmp/$name.probe" ] && [ ! -s "$tmp/$name.dispatch" ]
}
run_build_invalid missing-cargo-command cargo-command buck-artifact '--build-mode' --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --runtime-resource "$resource_root/runtime/buck2_artifact_runtime.txt" --source-denial "$resource_root/tools/cargo_source_denial.sh" --action-metadata-parser "$resource_root/tools/nextest_buck_artifact_action_metadata.py" --python-command "$(command -v python3)" --cargo-nextest-command "$resource_root/nextest_test_recorder.py" nextest --junit-report "$tmp/build-report.xml"
run_build_invalid missing-cargo-nextest-command cargo-nextest-command buck-artifact '--build-mode' --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --runtime-resource "$resource_root/runtime/buck2_artifact_runtime.txt" --source-denial "$resource_root/tools/cargo_source_denial.sh" --action-metadata-parser "$resource_root/tools/nextest_buck_artifact_action_metadata.py" --python-command "$(command -v python3)" --cargo-command "$resource_root/tools/cargo_source_denial.sh" --junit-report "$tmp/build-report.xml"
run_build_invalid missing-runtime-resource runtime-resource buck-artifact '--build-mode' --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --source-denial "$resource_root/tools/cargo_source_denial.sh" --action-metadata-parser "$resource_root/tools/nextest_buck_artifact_action_metadata.py" --python-command "$(command -v python3)" --cargo-command "$resource_root/tools/cargo_source_denial.sh" --cargo-nextest-command "$resource_root/nextest_test_recorder.py" nextest --junit-report "$tmp/build-report.xml"
run_build_invalid missing-source-denial source-denial buck-artifact '--build-mode' --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --runtime-resource "$resource_root/runtime/buck2_artifact_runtime.txt" --action-metadata-parser "$resource_root/tools/nextest_buck_artifact_action_metadata.py" --python-command "$(command -v python3)" --cargo-command "$resource_root/tools/cargo_source_denial.sh" --cargo-nextest-command "$resource_root/nextest_test_recorder.py" nextest --junit-report "$tmp/build-report.xml"
run_build_invalid missing-python-command python-command buck-artifact '--build-mode' --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --runtime-resource "$resource_root/runtime/buck2_artifact_runtime.txt" --source-denial "$resource_root/tools/cargo_source_denial.sh" --action-metadata-parser "$resource_root/tools/nextest_buck_artifact_action_metadata.py" --cargo-command "$resource_root/tools/cargo_source_denial.sh" --cargo-nextest-command "$resource_root/nextest_test_recorder.py" nextest --junit-report "$tmp/build-report.xml"
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
