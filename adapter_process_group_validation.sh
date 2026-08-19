#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
artifact=$1
manifest=$2
validator=$3
cargo_baseline=$4
binary_baseline=$5
tests_baseline=$6
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
shell=$(command -v sh || true)
python=$(command -v python3 || true)
env_bin=$(command -v env || true)
missing=
for utility in mkdir cp chmod mktemp dirname rm grep sed cat; do
    path=$(command -v "$utility" || true)
    [ -n "$path" ] || missing="$utility"
done
if [ -z "$shell" ] || [ -z "$python" ] || [ -z "$env_bin" ] || [ -n "$missing" ]; then
    printf 'adapter missing-setsid: BLOCKED (reason=required executable unavailable: %s)\n' "${missing:-shell/python/env}"
    exit 0
fi
bin=$tmp/bin
mkdir "$bin"
for path in "$shell" "$python" "$env_bin"; do cp "$path" "$bin/$(basename "$path")"; done
for utility in mkdir cp chmod mktemp dirname rm grep sed cat; do
    path=$(command -v "$utility")
    cp "$path" "$bin/$utility"
done
probe=$tmp/probe
dispatch=$tmp/dispatch
out=$tmp/out
: >"$probe"
: >"$dispatch"
set +e
"$env_bin" -i PATH="$bin" HOME="${HOME:-/tmp}" TMPDIR="${TMPDIR:-/tmp}" \
    BUCK_DEFAULT_RUNTIME_RESOURCES="$root" BUCK2_NEXTEST_REQUIRE_PROCESS_GROUP=1 \
    BUCK2_NEXTEST_PROBE_LOG="$probe" BUCK2_NEXTEST_DISPATCH_LOG="$dispatch" \
    BUCK2_NEXTEST_NESTED_CARGO_LOG="$tmp/nested" BUCK2_NEXTEST_COMPILER_LOG="$tmp/compiler" \
    "$root/adapter.sh" buck-artifact --build-mode --python-command "$python" --artifact "$artifact" --manifest "$manifest" --validator "$validator" \
    --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" \
    --cargo-command "$root/tools/cargo_source_denial.sh" --cargo-nextest-command "$root/nextest_test_recorder.py" nextest \
    --runtime-resource "$root/runtime/buck2_artifact_runtime.txt" --source-denial "$root/tools/cargo_source_denial.sh" \
    --junit-report "$tmp/report.xml" >"$out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || { cat "$out"; exit 1; }
grep -F 'setsid is required' "$out"
[ ! -s "$probe" ] && [ ! -s "$dispatch" ]
printf '%s\n' 'adapter missing-setsid validation: passed'
