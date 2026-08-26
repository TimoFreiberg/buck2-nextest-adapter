#!/bin/sh
set -eu

project=${BUCK_PROJECT_ROOT:-$(CDPATH= cd -- "$(dirname "$0")" && pwd)}
buck=${BUCK2:-buck2}
executor=$($buck build --show-output //:nextest_v2_executor | tail -1 | cut -d' ' -f2)
case "$executor" in
    /*) ;;
    *) executor="$project/$executor" ;;
esac
executor=$(CDPATH= cd -- "$(dirname "$executor")" && pwd)/$(basename "$executor")
tmp=$(CDPATH= cd -- "$(mktemp -d "${TMPDIR:-/private/tmp}/buck2-nextest-executor.XXXXXX")" && pwd -P)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/private" "$tmp/private/junit"
export BUCK_PROJECT_ROOT="$project"
export BUCK2_EXECUTOR_FIXTURE_NONCE="$(date +%s)-$$"

run_case() {
    mode=$1
    expected=$2
    dir="$tmp/$mode/private/junit"
    mkdir -p "$tmp/$mode/private"
    mkdir "$dir"
    export BUCK2_EXECUTOR_FIXTURE_MODE="$mode"
    set +e
    if [ "$mode" = timeout ]; then
        output=$($buck test --config "test.v2_test_executor=$executor" "//executor:nextest-v2-executor-fixture-$mode" -- --timeout 1 --junit-dir "$dir" 2>&1)
    else
        output=$($buck test --config "test.v2_test_executor=$executor" "//executor:nextest-v2-executor-fixture-$mode" -- --junit-dir "$dir" 2>&1)
    fi
    status=$?
    printf '%s\n' "$output" > "$tmp/$mode/output"
    printf '%s\n' "executor fixture mode=$mode status=$status" >&2
    set -e
    case "$expected" in
        pass) [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; exit 1; } ;;
        fail) [ "$status" -ne 0 ] || { printf '%s\n' "$output" >&2; exit 1; } ;;
        infra) [ "$status" -ne 0 ] || { printf '%s\n' "$output" >&2; exit 1; } ;;
    esac
    if [ "$mode" = pass ] || [ "$mode" = fail ]; then
        report=$(find "$dir" -type f -name '*.xml' -print -quit)
        [ -n "$report" ]
        case "$report" in *"nextest-v2-executor-fixture-$mode"*.xml) ;; *) exit 1 ;; esac
    elif [ "$mode" = timeout ]; then
        report=$(find "$dir" -type f -name '*.xml' -print -quit)
        [ -n "$report" ]
        case "$report" in *nextest-v2-executor-fixture-timeout*.xml) ;; *) exit 1 ;; esac
    else
        [ "$(find "$dir" -type f -name '*.xml' | wc -l | tr -d ' ')" -eq 0 ]
    fi
}

run_case pass pass
pass_xml=$(find "$tmp/pass/private/junit" -type f -name '*.xml' -print -quit)
[ -n "$pass_xml" ]
run_case fail fail
run_case timeout fail
run_case missing infra
run_case malformed infra
run_case symlink infra
run_case extra infra

# A mixed invocation proves that only the exact `nextest` spec receives the
# declared output and reserved environment. The ordinary fixture still runs
# through Execute2 but cannot publish a report.
mixed="$tmp/mixed/private/junit"
mkdir -p "$mixed"
set +e
mixed_output=$($buck test --config "test.v2_test_executor=$executor" \
    //executor:nextest-v2-executor-fixture-pass \
    //executor:nextest-v2-executor-fixture-ordinary -- --junit-dir "$mixed" 2>&1)
mixed_status=$?
set -e
[ "$mixed_status" -eq 0 ] || { printf '%s\n' "$mixed_output" >&2; exit 1; }
[ "$(find "$mixed" -type f -name '*.xml' | wc -l | tr -d ' ')" -eq 1 ]

# Separate fresh destinations plus per-run nonce demonstrate that reports are
# not accepted from a previous invocation or reused by test-result caching.
first="$tmp/fresh-one/private/junit"; second="$tmp/fresh-two/private/junit"
mkdir -p "$tmp/fresh-one/private" "$tmp/fresh-two/private"
mkdir "$first" "$second"
export BUCK2_EXECUTOR_FIXTURE_MODE=pass
export BUCK2_EXECUTOR_FIXTURE_NONCE="fresh-one-$$"
$buck test --config "test.v2_test_executor=$executor" //executor:nextest-v2-executor-fixture-pass -- --junit-dir "$first" >/dev/null 2>&1
export BUCK2_EXECUTOR_FIXTURE_NONCE="fresh-two-$$"
$buck test --config "test.v2_test_executor=$executor" //executor:nextest-v2-executor-fixture-pass -- --junit-dir "$second" >/dev/null 2>&1
first_xml=$(find "$first" -type f -name '*.xml' -print -quit)
second_xml=$(find "$second" -type f -name '*.xml' -print -quit)
[ -n "$first_xml" ]
[ -n "$second_xml" ]
if cmp -s "$first_xml" "$second_xml"; then
    printf '%s\n' 'fresh executor runs produced identical report bytes' >&2
    exit 1
fi
printf '%s\n' 'buck2 nextest executor junit: passed'
