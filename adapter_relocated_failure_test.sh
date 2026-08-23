#!/bin/sh
set -eu
root=${BUCK_PROJECT_ROOT:-$(cd "$(dirname "$0")" && pwd -P)}
phase=${1:?phase}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/adapter-relocated-failure-test.XXXXXX")
diag=$tmp/diagnostics
mkdir "$diag"
trap 'rm -rf "$tmp"' EXIT
set +e
output=$(TMPDIR="$tmp" ADAPTER_RELOCATED_DIAGNOSTIC_DIR="$diag" ADAPTER_RELOCATED_TEST_FAIL_PHASE="$phase" just adapter_relocated_sanitized 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || { printf '%s\n' "$output" >&2; exit 1; }
printf '%s\n' "$output" | grep -F "adapter relocated: phase=$phase" >/dev/null
for file in out probe dispatch argv.jsonl identity buck_outputs observability; do
    [ -f "$diag/$file" ] || { printf 'missing diagnostic=%s\n' "$file" >&2; exit 1; }
done
if [ "$phase" = cleanup ]; then
    [ "$status" -eq 70 ] || exit 1
else
    [ "$status" -ne 70 ] || exit 1
fi
printf 'adapter relocated %s failure test: passed\n' "$phase"
