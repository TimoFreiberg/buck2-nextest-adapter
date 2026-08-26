#!/bin/sh
set -eu

project=${BUCK_PROJECT_ROOT:-$(CDPATH= cd -- "$(dirname "$0")" && pwd)}
buck=${BUCK2:-buck2}
executor=$($buck build --show-output //:nextest_v2_executor | tail -1 | cut -d' ' -f2)
case "$executor" in /*) ;; *) executor="$project/$executor" ;; esac
tmp=$(CDPATH= cd -- "$(mktemp -d "${TMPDIR:-/private/tmp}/executor-protocol-tcp.XXXXXX")" && pwd -P)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/private" "$tmp/private/junit"
export BUCK_PROJECT_ROOT="$project"
export BUCK2_EXECUTOR_FIXTURE_MODE=pass
export BUCK2_TEST_TPX_USE_TCP=1
output=$($buck test --config "test.v2_test_executor=$executor" //executor:nextest-v2-executor-fixture-pass -- --junit-dir "$tmp/private/junit" 2>&1)
printf '%s\n' "$output" | grep -E 'Pass|PASS|pass' >/dev/null
[ "$(find "$tmp/private/junit" -type f -name '*.xml' | wc -l | tr -d ' ')" -eq 1 ]
printf '%s\n' 'executor protocol pinned TCP: passed'
