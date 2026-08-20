#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
artifact=$1
manifest=$2
validator=$3
cargo_baseline=$4
binary_baseline=$5
tests_baseline=$6
cargo_executable=$7
python_executable=$8
nextest_executable=$9
invocation_cwd=$(pwd -P)
for variable in artifact manifest validator cargo_baseline binary_baseline tests_baseline cargo_executable python_executable nextest_executable; do
    eval "value=\${$variable}"
    case "$value" in
        /*) ;;
        *) eval "$variable=\$invocation_cwd/\$value" ;;
    esac
done
run_root=$(mktemp -d "${TMPDIR:-/tmp}/adapter-hermetic.XXXXXX") || { printf 'mktemp failed\n' >&2; exit 1; }
trap 'rm -rf "$run_root"' EXIT

make_bin() {
    bin=$1
    mkdir "$bin" || { printf 'mkdir bin failed\n' >&2; exit 1; }
    for utility in sh env mkdir cp chmod mktemp dirname rm grep sed cat basename tr wc bash realpath awk; do
        path=$(command -v "$utility" || true)
        [ -n "$path" ] || { printf 'missing utility: %s\n' "$utility" >&2; exit 1; }
        cp "$path" "$bin/$utility"
    done
}

bin="$run_root/bin"
make_bin "$bin"
probe="$run_root/probe"
dispatch="$run_root/dispatch"
argv_log="$run_root/argv.jsonl"
cleanup_log="$run_root/cleanup.log"
out="$run_root/out"
: >"$probe"
: >"$dispatch"
: >"$argv_log"

PATH="$bin" HOME="${HOME:-/tmp}" TMPDIR="$run_root" \
BUCK_DEFAULT_RUNTIME_RESOURCES="$root" \
BUCK2_NEXTEST_PROBE_LOG="$probe" BUCK2_NEXTEST_DISPATCH_LOG="$dispatch" \
BUCK2_NEXTEST_ARGV_LOG="$argv_log" BUCK2_NEXTEST_CLEANUP_LOG="$cleanup_log" \
BUCK2_NEXTEST_REAL_CARGO="$root/tools/cargo_source_denial.sh" \
"$root/adapter.sh" buck-artifact --build-mode \
    --artifact "$artifact" --manifest "$manifest" --validator "$validator" \
    --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" \
    --cargo-command "$cargo_executable" --python-command "$python_executable" \
    --cargo-nextest-command "$nextest_executable" nextest \
    --runtime-resource "$root/runtime/buck2_artifact_runtime.txt" \
    --source-denial "$root/tools/cargo_source_denial.sh" --junit-report "$run_root/report.xml" >"$out" 2>&1 || { cat "$out" >&2; exit 1; }


[ -s "$argv_log" ] || { cat "$out" >&2; find "$run_root" -maxdepth 2 -type f -print >&2; exit 1; }
[ -s "$out" ] || { printf 'adapter produced no output\n' >&2; exit 1; }
[ ! -s "$probe" ] || { cat "$out" >&2; exit 1; }
[ -s "$dispatch" ] || { cat "$out" >&2; exit 1; }
[ -s "$run_root/report.xml" ] || { cat "$out" >&2; exit 1; }
"$python_executable" - "$run_root/report.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
assert [x.attrib["name"] for x in ET.parse(sys.argv[1]).getroot().iter("testcase")] == ["pass_case"]
PY
[ "$(grep -c 'cleanup=once' "$out")" -eq 1 ] || { cat "$out" >&2; exit 1; }
private_root=$(sed -n 's/.*manifest-root=//p' "$out")
[ -n "$private_root" ] && [ ! -e "$private_root" ]

set +e
PATH="$bin" HOME="${HOME:-/tmp}" TMPDIR="$run_root" \
BUCK_DEFAULT_RUNTIME_RESOURCES="$root" BUCK2_NEXTEST_PROBE_LOG="$probe" \
BUCK2_NEXTEST_DISPATCH_LOG="$dispatch" BUCK2_NEXTEST_ARGV_LOG="$argv_log" \
"$root/adapter.sh" buck-artifact --build-mode \
    --artifact "$artifact" --manifest "$manifest" --validator "$validator" \
    --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" \
    --python-command "$python_executable" --cargo-nextest-command "$nextest_executable" nextest \
    --runtime-resource "$root/runtime/buck2_artifact_runtime.txt" \
    --source-denial "$root/tools/cargo_source_denial.sh" --junit-report "$run_root/missing.xml" >"$run_root/missing.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ]
grep -F 'build mode requires --cargo-command' "$run_root/missing.out"
printf '%s\n' 'adapter declared-tool restricted-PATH fixture: unresolved environment-specific follow-up' >&2
exit 1
