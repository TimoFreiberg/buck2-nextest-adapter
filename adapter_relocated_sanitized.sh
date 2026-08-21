#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-$(cd "$(dirname "$0")" && pwd -P)}
artifact=$1
manifest=$2
validator=$3
cargo_baseline=$4
binary_baseline=$5
tests_baseline=$6
python_executable=$7
nextest_executable=$8
run_root=$(mktemp -d "${TMPDIR:-/tmp}/adapter-relocated.XXXXXX")
run_root=$(cd "$run_root" && pwd -P)
trap 'rm -rf "$run_root"' EXIT
bin="$run_root/bin"
mkdir "$bin"
for utility in sh env mkdir cp chmod mktemp dirname rm grep sed cat basename tr wc bash realpath awk cut tail python3 sha256sum shasum ln; do
    # Buck may provide symlinked tools; copy the resolved executable into PATH.
    path=$(command -v "$utility" || true)
    [ -n "$path" ] || { echo "missing utility: $utility" >&2; exit 1; }
    case "$path" in
        /*) resolved=$path ;;
        *) resolved=$(realpath "$path" 2>/dev/null || printf '%s' "$path") ;;
    esac
    ln -s "$resolved" "$bin/$utility"
done
scratch="$run_root/buck-scratch"
mkdir "$scratch"
mkdir -p "$run_root/ambient-tmp"
relocated="$run_root/relocated"
mkdir "$relocated"
report="$run_root/report.xml"
out="$run_root/out"
: >"$out"
probe="$run_root/probe"
dispatch="$run_root/dispatch"
argv_log="$run_root/argv.jsonl"
: >"$probe"; : >"$dispatch"; : >"$argv_log"
old_cwd=$(pwd -P)
report="$run_root/report.xml"
cd "$relocated"
if ! env PATH="$bin" HOME="$run_root/home" TMPDIR="$run_root/ambient-tmp" \
BUCK_SCRATCH_PATH="$scratch" BUCK_DEFAULT_RUNTIME_RESOURCES="$root" \
BUCK2_NEXTEST_PROBE_LOG="$probe" BUCK2_NEXTEST_DISPATCH_LOG="$dispatch" \
BUCK2_NEXTEST_ARGV_LOG="$argv_log" \
"$root/adapter.sh" buck-artifact --build-mode \
    --artifact "$artifact" --manifest "$manifest" --validator "$validator" \
    --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" \
    --cargo-command "$root/tools/cargo_source_denial.sh" --python-command /usr/bin/python3 \
    --cargo-nextest-command "$nextest_executable" nextest \
    --runtime-resource "$root/runtime/buck2_artifact_runtime.txt" \
    --source-denial "$root/tools/cargo_source_denial.sh" \
    --action-metadata-parser "$root/tools/nextest_buck_artifact_action_metadata.py" \
    --junit-report "$report" >"$out" 2>&1; then
    cd "$old_cwd"
    cat "$out" >&2
    exit 1
fi
cd "$old_cwd"
if [ ! -s "$report" ]; then cat "$out"; exit 1; fi
[ ! -s "$probe" ]
[ -s "$argv_log" ]
grep -F 'buck2-nextest-adapter: junit-report=' "$out" >/dev/null
private_root=$(sed -n 's/.*cleanup=once root=//p' "$out")
case "$private_root" in
    "$scratch"/*) ;;
    *) cat "$out" >&2; exit 1 ;;
esac
[ ! -e "$private_root" ]
[ ! -e "$run_root/ambient-tmp/buck2-nextest-buck-artifact" ]
[ "$(grep -c 'cleanup=once' "$out")" -eq 1 ]
python3 - "$report" <<'PY'
import sys
import xml.etree.ElementTree as ET
assert [x.attrib["name"] for x in ET.parse(sys.argv[1]).getroot().iter("testcase")] == ["pass_case"]
PY
printf '%s\n' 'adapter relocated sanitized: passed'
