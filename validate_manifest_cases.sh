#!/bin/sh
set -eu

artifact=${1:-}
manifest_input=${2:-}
generated_manifest=${3:-}
if [ -z "$artifact" ] || [ -z "$manifest_input" ] || [ -z "$generated_manifest" ]; then
    printf '%s\n' 'validate_manifest_cases: expected artifact, manifest input, and generated manifest' >&2
    exit 2
fi
for omitted in artifact manifest generated; do
    set +e
    case "$omitted" in
        artifact) "$0" >"${TMPDIR:-/tmp}/validate-manifest-$omitted.out" 2>&1 ;;
        manifest) "$0" "$artifact" >"${TMPDIR:-/tmp}/validate-manifest-$omitted.out" 2>&1 ;;
        generated) "$0" "$artifact" "$manifest_input" >"${TMPDIR:-/tmp}/validate-manifest-$omitted.out" 2>&1 ;;
    esac
    status=$?
    set -e
    [ "$status" -eq 2 ]
    grep -Fx 'validate_manifest_cases: expected artifact, manifest input, and generated manifest' "${TMPDIR:-/tmp}/validate-manifest-$omitted.out"
done
root=$(mktemp -d "${TMPDIR:-/tmp}/manifest-cases.XXXXXX")
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/work" "$root/runtime"
cp "$artifact" "$root/bin/buck2_nextest_rust_test"
chmod +x "$root/bin/buck2_nextest_rust_test"
printf 'buck2-nextest-artifact-runtime-v1\n' > "$root/runtime/buck2_artifact_runtime.txt"
resource_root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
validator=$resource_root/tools/nextest_artifact.py
example_manifest=$resource_root/artifact-manifest.example.json
cp "$manifest_input" "$root/manifest-input.json"
cp "$example_manifest" "$root/manifest.json"
python3 "$validator" validate-manifest --manifest "$root/manifest-input.json" --root "$root" --allow-missing
python3 "$validator" validate-manifest --manifest "$root/manifest.json" --root "$root"
python3 "$validator" validate-manifest --manifest "$generated_manifest" --root "$root" --allow-missing
python3 - "$root/manifest-input.json" "$root/manifest.json" "$generated_manifest" <<'PY'
import json
import sys
expected = [
    {"name": "pass_case", "ignored": False},
    {"name": "fail_case", "ignored": False},
    {"name": "ignored_case", "ignored": True},
    {"name": "timeout_case", "ignored": False},
]
for path in sys.argv[1:]:
    value = json.load(open(path))
    assert value["artifact"]["test_cases"] == expected, path
PY

run_case() {
    name=$1
    body=$2
    printf '%s\n' "$body" > "$root/$name.json"
    set +e
    python3 tools/nextest_artifact.py validate-manifest --manifest "$root/$name.json" --root "$root" >"$root/$name.out" 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] || { cat "$root/$name.out"; exit 1; }
    ! grep -F 'NEXTTEST_EXECUTION_MARKER' "$root/$name.out"
    printf 'manifest-case: %s rejected\n' "$name"
}

base=$(cat "$root/manifest.json")
run_case malformed '{'
run_case duplicate '{"schema_version":1,"schema_version":1}'
run_case unknown_version '{"schema_version":2}'
run_case wrong_type '{"schema_version":"1"}'
run_case missing_executable '{"schema_version":1,"artifact":{},"paths":{},"environment":{},"platform":{},"build":{}}'
run_case absolute_path '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":[{"name":"pass_case","ignored":false},{"name":"fail_case","ignored":false},{"name":"ignored_case","ignored":true}]},"paths":{"executable":"/tmp/x","working_directory":"work","runtime_inputs":["runtime/buck2_artifact_runtime.txt"]},"environment":{"BUCK2_ARTIFACT_RUNTIME":"declared"},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":[]}}'
run_case traversal_path '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":[{"name":"pass_case","ignored":false},{"name":"fail_case","ignored":false},{"name":"ignored_case","ignored":true}]},"paths":{"executable":"../x","working_directory":"work","runtime_inputs":["runtime/buck2_artifact_runtime.txt"]},"environment":{"BUCK2_ARTIFACT_RUNTIME":"declared"},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":[]}}'
run_case reserved_environment '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":[{"name":"pass_case","ignored":false},{"name":"fail_case","ignored":false},{"name":"ignored_case","ignored":true}]},"paths":{"executable":"bin/buck2_nextest_rust_test","working_directory":"work","runtime_inputs":["runtime/buck2_artifact_runtime.txt"]},"environment":{"BUCK2_NEXTEST_RUNTIME":"declared"},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":[]}}'
run_case duplicate_runtime '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":[{"name":"pass_case","ignored":false},{"name":"fail_case","ignored":false},{"name":"ignored_case","ignored":true}]},"paths":{"executable":"bin/buck2_nextest_rust_test","working_directory":"work","runtime_inputs":["runtime/buck2_artifact_runtime.txt","runtime/buck2_artifact_runtime.txt"]},"environment":{"BUCK2_ARTIFACT_RUNTIME":"declared"},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":[]}}'
run_case generated_outputs '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":[{"name":"pass_case","ignored":false},{"name":"fail_case","ignored":false},{"name":"ignored_case","ignored":true}]},"paths":{"executable":"bin/buck2_nextest_rust_test","working_directory":"work","runtime_inputs":["runtime/buck2_artifact_runtime.txt"]},"environment":{"BUCK2_ARTIFACT_RUNTIME":"declared"},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":["x"]}}'
run_case adapter_owned_runtime '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":[{"name":"pass_case","ignored":false},{"name":"fail_case","ignored":false},{"name":"ignored_case","ignored":true}]},"paths":{"executable":"bin/buck2_nextest_rust_test","working_directory":"work","runtime_inputs":["manifest.json"]},"environment":{"BUCK2_ARTIFACT_RUNTIME":"declared"},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":[]}}'
ln -s "$root/bin" "$root/link"
run_case symlink_escape '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":[{"name":"pass_case","ignored":false},{"name":"fail_case","ignored":false},{"name":"ignored_case","ignored":true}]},"paths":{"executable":"link/buck2_nextest_rust_test","working_directory":"work","runtime_inputs":["runtime/buck2_artifact_runtime.txt"]},"environment":{"BUCK2_ARTIFACT_RUNTIME":"declared"},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":[]}}'
run_case wrong_environment_type '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":[{"name":"pass_case","ignored":false},{"name":"fail_case","ignored":false},{"name":"ignored_case","ignored":true}]},"paths":{"executable":"bin/buck2_nextest_rust_test","working_directory":"work","runtime_inputs":["runtime/buck2_artifact_runtime.txt"]},"environment":{"BUCK2_ARTIFACT_RUNTIME":1},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":[]}}'
run_case invalid_environment_name '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":[{"name":"pass_case","ignored":false},{"name":"fail_case","ignored":false},{"name":"ignored_case","ignored":true}]},"paths":{"executable":"bin/buck2_nextest_rust_test","working_directory":"work","runtime_inputs":["runtime/buck2_artifact_runtime.txt"]},"environment":{"1BAD":"x"},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":[]}}'

python3 - "$root" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
base = json.loads((root / "manifest.json").read_text())

def write(name, cases):
    value = json.loads(json.dumps(base))
    value["artifact"]["test_cases"] = cases
    (root / f"{name}.json").write_text(json.dumps(value))

write("record_type", ["pass_case", "fail_case", "ignored_case", "timeout_case"])
write("record_missing_name", [{"ignored": False}, {"name": "fail_case", "ignored": False}, {"name": "ignored_case", "ignored": True}, {"name": "timeout_case", "ignored": False}])
write("record_unknown_field", [{"name": "pass_case", "ignored": False, "extra": 1}, {"name": "fail_case", "ignored": False}, {"name": "ignored_case", "ignored": True}, {"name": "timeout_case", "ignored": False}])
write("record_empty_name", [{"name": "", "ignored": False}, {"name": "fail_case", "ignored": False}, {"name": "ignored_case", "ignored": True}, {"name": "timeout_case", "ignored": False}])
write("record_duplicate", [{"name": "pass_case", "ignored": False}, {"name": "pass_case", "ignored": False}, {"name": "ignored_case", "ignored": True}, {"name": "timeout_case", "ignored": False}])
write("record_invalid_bool", [{"name": "pass_case", "ignored": 0}, {"name": "fail_case", "ignored": False}, {"name": "ignored_case", "ignored": True}, {"name": "timeout_case", "ignored": False}])
write("record_missing", [{"name": "pass_case", "ignored": False}, {"name": "fail_case", "ignored": False}, {"name": "ignored_case", "ignored": True}])
write("record_extra", [{"name": "pass_case", "ignored": False}, {"name": "fail_case", "ignored": False}, {"name": "ignored_case", "ignored": True}, {"name": "timeout_case", "ignored": False}, {"name": "extra_case", "ignored": False}])
write("record_reordered", [{"name": "fail_case", "ignored": False}, {"name": "pass_case", "ignored": False}, {"name": "ignored_case", "ignored": True}, {"name": "timeout_case", "ignored": False}])
PY
for case in record_type record_missing_name record_unknown_field record_empty_name record_duplicate record_invalid_bool record_missing record_extra record_reordered; do
    run_case "$case" "$(cat "$root/$case.json")"
done

printf 'manifest-case: negative suite passed\n'
