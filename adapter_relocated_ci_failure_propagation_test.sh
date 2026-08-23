#!/bin/sh
set -eu
root=${BUCK_PROJECT_ROOT:-$(cd "$(dirname "$0")" && pwd -P)}
set +e
output=$(cd "$root" && ADAPTER_RELOCATED_TEST_FAIL_PHASE=adapter just --jobs 4 ci 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || { printf '%s\n' "$output" >&2; exit 1; }
printf '%s\n' "$output" | grep -F 'adapter relocated: phase=adapter' >/dev/null
printf '%s\n' 'adapter relocated CI failure propagation test: passed'
