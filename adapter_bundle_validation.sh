#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
adapter=$root/adapter.sh
artifact=${1:-}
manifest=${2:-}
validator=${3:-}
cargo_baseline=${4:-}
binary_baseline=${5:-}
tests_baseline=${6:-}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/adapter-bundle-validation.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)
mkdir -p "$tmp/out"
mkdir -p "$tmp/out/parent"
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/action-metadata.json"
python3 - "$tmp/bundle-resource.txt" <<'PY'
from pathlib import Path
Path(__import__('sys').argv[1]).write_text('bundle fixture\n', encoding='utf-8')
PY
resource=$tmp/bundle-resource.txt
digest=$(sha256sum "$resource" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$resource" | awk '{print $1}')
size=$(wc -c <"$resource" | tr -d ' ')
python_launcher=$root/tools/nextest_python_launcher.sh
[ -x "$python_launcher" ] || python_launcher="$root/../tools/nextest_python_launcher.sh"
recorder=$root/nextest_test_recorder.py
[ -f "$recorder" ] || recorder="$root/../nextest_test_recorder.py"
recorder=$(cd "$(dirname "$recorder")" && pwd -P)/$(basename "$recorder")
python_launcher=$(cd "$(dirname "$python_launcher")" && pwd -P)/$(basename "$python_launcher")
run_invalid() {
    name=$1
    json=$2
    resources=$3
    set +e
    BUCK2_NEXTEST_ACTION_METADATA=$tmp/action-metadata.json \
    BUCK2_NEXTEST_PROBE_LOG=$tmp/$name.probe \
    BUCK2_NEXTEST_DISPATCH_LOG=$tmp/$name.dispatch \
        "$adapter" buck-artifact --build-mode \
        --artifact "$artifact" --manifest "$manifest" --validator "$validator" \
        --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" \
        --tests-baseline "$tests_baseline" \
        --cargo-argv "$root/tools/cargo_source_denial.sh" --end-argv \
        --python-argv "$python_launcher" --end-argv \
        --cargo-nextest-argv "$recorder" nextest --end-argv \
        --runtime-resource "$root/runtime/buck2_artifact_runtime.txt" \
        --source-denial "$root/tools/cargo_source_denial.sh" \
        --action-metadata-parser "$root/tools/nextest_buck_artifact_action_metadata.py" \
        --junit-report "$tmp/out/parent/valid-report.xml" \
        --bundle-json "$json" --bundle-resources "$resources" --end-bundle-resources \
        >"$tmp/$name.out" 2>&1
    status=$?
    set -e
    [ "$status" -eq 2 ] || { cat "$tmp/$name.out" >&2; exit 1; }
    [ ! -s "$tmp/$name.probe" ] && [ ! -s "$tmp/$name.dispatch" ]
}
valid='{"bundle_environment":[{"kind":"relative_path","name":"BUNDLE_FIXTURE_PATH","value":"runtime/resource.txt"},{"kind":"literal","name":"BUNDLE_FIXTURE_LITERAL","value":"declared"}],"bundle_platform":"fixture-v1","bundle_resources":[{"digest":"sha256:'$digest':'$size'","path":"runtime/resource.txt","source":"bundle-resource.txt"}],"bundle_version":1}'
run_invalid missing-resource "$valid" "$tmp/missing.txt"
run_invalid bad-digest "${valid/$digest/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" "$resource"
run_invalid bad-platform "${valid/fixture-v1/bad platform}" "$resource"
run_invalid traversal "${valid/runtime\\/resource.txt/..\\/resource.txt}" "$resource"
set +e
    "$adapter" buck-artifact --build-mode \
    --artifact "$artifact" --manifest "$manifest" --validator "$validator" \
    --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" \
    --tests-baseline "$tests_baseline" \
    --cargo-argv "$root/tools/cargo_source_denial.sh" --end-argv \
    --python-argv "$python_launcher" --end-argv \
    --cargo-nextest-argv "$recorder" nextest --end-argv \
    --runtime-resource "$root/runtime/buck2_artifact_runtime.txt" \
    --source-denial "$root/tools/cargo_source_denial.sh" \
    --action-metadata-parser "$root/tools/nextest_buck_artifact_action_metadata.py" \
    --junit-report "$tmp/out/parent/valid-report.xml" \
    --bundle-json "$valid" --bundle-resources "$resource" --end-bundle-resources \
    >"$tmp/valid.out" 2>&1
valid_status=$?
set -e
[ "$valid_status" -eq 0 ] || { cat "$tmp/valid.out" >&2; exit 1; }
grep -F 'cleanup=once' "$tmp/valid.out" >/dev/null
printf '%s\n' 'adapter bundle validation: passed'
