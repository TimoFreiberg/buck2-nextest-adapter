#!/bin/sh
set -eu
root=${BUCK_PROJECT_ROOT:-$(cd "$(dirname "$0")" && pwd -P)}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/adapter-relocated-path-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
buck=${BUCK2:-buck2}
build_output() { "$buck" "$@"; }
artifact=$(build_output build --show-output //:buck2_nextest_rust_test | tail -1 | cut -d' ' -f2)
manifest=$(build_output build --show-output //:buck2_nextest_artifact_manifest | tail -1 | cut -d' ' -f2)
runner=$(build_output build --show-output //:nextest_buck_artifact_runner | tail -1 | cut -d' ' -f2)
nextest=$(build_output build --show-output //:nextest-cargo-nextest-v1-executable | tail -1 | cut -d' ' -f2)
for output in artifact manifest runner nextest; do
    eval "value=\${$output:-}"
    [ -n "$value" ] || { printf 'relocation path test: missing Buck output=%s\n' "$output" >&2; exit 1; }
done
relative_artifact=${artifact#"$root/"}
relative_manifest=${manifest#"$root/"}
relative_runner=${runner#"$root/"}
relative_nextest=${nextest#"$root/"}
# The production harness must derive relative raw outputs lexically and complete.
BUCK_PROJECT_ROOT="$root" ADAPTER_RELOCATED_ARTIFACT_BUCK_OUTPUT_PATH="$relative_artifact" \
ADAPTER_RELOCATED_MANIFEST_BUCK_OUTPUT_PATH="$relative_manifest" \
ADAPTER_RELOCATED_RUNNER_BUCK_OUTPUT_PATH="$relative_runner" \
ADAPTER_RELOCATED_NEXTEST_BUCK_OUTPUT_PATH="$relative_nextest" \
"$root/adapter_relocated_sanitized.sh" "$relative_artifact" "$relative_manifest" "$relative_runner" \
  "$root/baseline/normalized/cargo-metadata.json" "$root/baseline/normalized/binaries.json" "$root/baseline/normalized/tests.json" \
  "$relative_nextest" >"$tmp/pass.out" 2>&1
grep -F 'adapter relocated sanitized: passed' "$tmp/pass.out" >/dev/null
# A final symlink is rejected at the same production validation boundary.
symlink_dir=$tmp/symlink
mkdir -p "$symlink_dir"
ln -s "$root/$relative_artifact" "$symlink_dir/artifact"
set +e
BUCK_PROJECT_ROOT="$root" ADAPTER_RELOCATED_ARTIFACT_BUCK_OUTPUT_PATH="$symlink_dir/artifact" \
ADAPTER_RELOCATED_MANIFEST_BUCK_OUTPUT_PATH="$manifest" \
ADAPTER_RELOCATED_RUNNER_BUCK_OUTPUT_PATH="$runner" \
ADAPTER_RELOCATED_NEXTEST_BUCK_OUTPUT_PATH="$nextest" \
"$root/adapter_relocated_sanitized.sh" "$symlink_dir/artifact" "$manifest" "$runner" \
  "$root/baseline/normalized/cargo-metadata.json" "$root/baseline/normalized/binaries.json" "$root/baseline/normalized/tests.json" \
  "$nextest" >"$tmp/symlink.out" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
grep -F 'adapter relocated: phase=setup message=Buck output escaped project root' "$tmp/symlink.out" >/dev/null
! grep -F 'top-level cargo nextest dispatch' "$tmp/symlink.out" >/dev/null

# A symlinked BUCK_SCRATCH_PATH ancestor must be rejected before the runner
# creates its private root outside the action working directory.
runtime="$root/runtime/buck2_artifact_runtime.txt"
runtime_digest=$(sha256sum "$runtime" | awk '{print $1}')
runtime_size=$(wc -c <"$runtime" | tr -d ' ')
bundle_json="{\"bundle_environment\":[],\"bundle_platform\":\"scratch-link-v1\",\"bundle_resources\":[{\"digest\":\"sha256:$runtime_digest:$runtime_size\",\"path\":\"runtime/buck2_artifact_runtime.txt\",\"source\":\"runtime/buck2_artifact_runtime.txt\"}],\"bundle_version\":1}"
scratch_outside="$tmp/scratch-outside"
runner_abs="$root/$runner"
artifact_abs="$root/$artifact"
manifest_abs="$root/$manifest"
nextest_abs="$root/$nextest"
mkdir "$scratch_outside"
ln -s "$scratch_outside" "$tmp/scratch-link"
set +e
(
    cd "$tmp"
    BUCK_SCRATCH_PATH=scratch-link/child "$runner_abs" buck-artifact --build-mode \
        --artifact "$artifact_abs" --manifest "$manifest_abs" \
        --cargo-baseline "$root/baseline/normalized/cargo-metadata.json" \
        --binary-baseline "$root/baseline/normalized/binaries.json" \
        --tests-baseline "$root/baseline/normalized/tests.json" \
        --cargo-nextest-argv "$nextest_abs" --end-argv \
        --bundle-json "$bundle_json" --bundle-resources "$runtime" --end-bundle-resources \
        --runtime-resource "$runtime" --junit-report "$tmp/invalid-report.xml"
) >"$tmp/scratch-symlink.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ]
grep -F 'BUCK_SCRATCH_PATH' "$tmp/scratch-symlink.out" >/dev/null
[ -z "$(find "$scratch_outside" -mindepth 1 -print -quit)" ]
printf '%s\n' 'adapter relocated path derivation test: passed'
