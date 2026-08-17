#!/bin/sh
set -eu
artifact=$1
manifest=$2
validator=$3
cargo_baseline=$4
binary_baseline=$5
tests_baseline=$6
summary=$7
tmp=$(mktemp -d "./.buck2-nextest-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/root/bin" "$tmp/root/work" "$tmp/root/runtime" "$tmp/target" "$tmp/workspace"
cp "$artifact" "$tmp/root/bin/buck2_nextest_rust_test"
chmod +x "$tmp/root/bin/buck2_nextest_rust_test"
cp "$manifest" "$tmp/root/manifest.json"
cp "${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}/runtime/buck2_artifact_runtime.txt" "$tmp/root/runtime/buck2_artifact_runtime.txt"
python3 "$validator" synthesize --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --target-dir "$tmp/target" --workspace "$tmp/workspace" --output-dir "$tmp/meta" --manifest "$tmp/root/manifest.json" --manifest-root "$tmp/root"
python3 - "$tmp/meta/tests-metadata.json" "$tests_baseline" "$binary_baseline" "$summary" <<'PY'
import json, sys
synthetic, tests, binaries, summary = map(lambda p: json.load(open(p)), sys.argv[1:])
suite = synthetic['rust-suites']['buck2_nextest_rust_test']
assert synthetic['test-count'] == 4
assert list(suite['testcases']) == ['pass_case', 'fail_case', 'ignored_case', 'timeout_case']
assert [suite['testcases'][n]['ignored'] for n in suite['testcases']] == [False, False, True, False]
assert tests['test-count'] == 2
assert len(binaries['rust-binaries']) == 3
assert summary['observed_test_cases'] == ['pass_case', 'fail_case']
assert summary['observed_test_binaries'] == ['fail_case', 'pass_case']
PY
printf '%s\n' 'buck artifact metadata: passed'
