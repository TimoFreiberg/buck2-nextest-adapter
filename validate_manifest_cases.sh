#!/bin/sh
set -eu

root=$(mktemp -d "${TMPDIR:-/tmp}/manifest-cases.XXXXXX")
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/work" "$root/runtime"
artifact=${1:-}
if [ -n "$artifact" ]; then
    cp "$artifact" "$root/bin/buck2_nextest_rust_test"
else
    printf '#!/bin/sh\n' > "$root/bin/buck2_nextest_rust_test"
fi
chmod +x "$root/bin/buck2_nextest_rust_test"
printf 'buck2-nextest-artifact-runtime-v1\n' > "$root/runtime/buck2_artifact_runtime.txt"
cp artifact-manifest.example.json "$root/manifest.json"
python3 tools/nextest_artifact.py validate-manifest --manifest "$root/manifest.json" --root "$root" --allow-missing
python3 tools/nextest_artifact.py validate-manifest --manifest "$root/manifest.json" --root "$root" >/dev/null

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

run_case malformed '{'
run_case duplicate '{"schema_version":1,"schema_version":1}'
run_case unknown_version '{"schema_version":2}'
run_case wrong_type '{"schema_version":"1"}'
run_case missing_executable '{"schema_version":1,"artifact":{},"paths":{},"environment":{},"platform":{},"build":{}}'
run_case absolute_path '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":["pass_case","fail_case"]},"paths":{"executable":"/tmp/x","working_directory":"work","runtime_inputs":["runtime/buck2_artifact_runtime.txt"]},"environment":{"BUCK2_ARTIFACT_RUNTIME":"declared"},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":[]}}'
run_case traversal_path '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":["pass_case","fail_case"]},"paths":{"executable":"../x","working_directory":"work","runtime_inputs":["runtime/buck2_artifact_runtime.txt"]},"environment":{"BUCK2_ARTIFACT_RUNTIME":"declared"},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":[]}}'
run_case reserved_environment '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":["pass_case","fail_case"]},"paths":{"executable":"bin/buck2_nextest_rust_test","working_directory":"work","runtime_inputs":["runtime/buck2_artifact_runtime.txt"]},"environment":{"BUCK2_NEXTEST_RUNTIME":"declared"},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":[]}}'
run_case duplicate_runtime '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":["pass_case","fail_case"]},"paths":{"executable":"bin/buck2_nextest_rust_test","working_directory":"work","runtime_inputs":["runtime/buck2_artifact_runtime.txt","runtime/buck2_artifact_runtime.txt"]},"environment":{"BUCK2_ARTIFACT_RUNTIME":"declared"},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":[]}}'
run_case generated_outputs '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":["pass_case","fail_case"]},"paths":{"executable":"bin/buck2_nextest_rust_test","working_directory":"work","runtime_inputs":["runtime/buck2_artifact_runtime.txt"]},"environment":{"BUCK2_ARTIFACT_RUNTIME":"declared"},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":["x"]}}'
ln -s "$root/bin" "$root/link"
run_case symlink_escape '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":["pass_case","fail_case"]},"paths":{"executable":"link/buck2_nextest_rust_test","working_directory":"work","runtime_inputs":["runtime/buck2_artifact_runtime.txt"]},"environment":{"BUCK2_ARTIFACT_RUNTIME":"declared"},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":[]}}'
run_case wrong_environment_type '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":["pass_case","fail_case"]},"paths":{"executable":"bin/buck2_nextest_rust_test","working_directory":"work","runtime_inputs":["runtime/buck2_artifact_runtime.txt"]},"environment":{"BUCK2_ARTIFACT_RUNTIME":1},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":[]}}'
run_case invalid_environment_name '{"schema_version":1,"artifact":{"package_name":"buck2-nextest-buck-artifact","binary_id":"buck2_nextest_rust_test","binary_name":"buck2_nextest_rust_test","target_kind":"test","test_cases":["pass_case","fail_case"]},"paths":{"executable":"bin/buck2_nextest_rust_test","working_directory":"work","runtime_inputs":["runtime/buck2_artifact_runtime.txt"]},"environment":{"1BAD":"x"},"platform":{"target_triple":"x","target_features":"unknown"},"build":{"generated_outputs":[]}}'

printf 'manifest-case: negative suite passed\n'
