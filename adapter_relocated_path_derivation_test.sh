#!/bin/sh
set -eu
root=${BUCK_PROJECT_ROOT:-$(cd "$(dirname "$0")" && pwd -P)}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/adapter-relocated-path-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
build_output() { "$root/buck2" "$@"; }
artifact=$(buck2 build --show-output //:buck2_nextest_rust_test | tail -1 | cut -d' ' -f2)
manifest=$(buck2 build --show-output //:buck2_nextest_artifact_manifest | tail -1 | cut -d' ' -f2)
python=$(buck2 build --show-output //:nextest-python-executable | tail -1 | cut -d' ' -f2)
nextest=$(buck2 build --show-output //:nextest-cargo-nextest-v1-executable | tail -1 | cut -d' ' -f2)
relative_artifact=${artifact#"$root/"}
relative_manifest=${manifest#"$root/"}
relative_python=${python#"$root/"}
relative_nextest=${nextest#"$root/"}
# The production harness must derive relative raw outputs lexically and complete.
BUCK_PROJECT_ROOT="$root" ADAPTER_RELOCATED_ARTIFACT_BUCK_OUTPUT_PATH="$relative_artifact" \
ADAPTER_RELOCATED_MANIFEST_BUCK_OUTPUT_PATH="$relative_manifest" \
ADAPTER_RELOCATED_PYTHON_BUCK_OUTPUT_PATH="$relative_python" \
ADAPTER_RELOCATED_NEXTEST_BUCK_OUTPUT_PATH="$relative_nextest" \
"$root/adapter_relocated_sanitized.sh" "$relative_artifact" "$relative_manifest" "$root/tools/nextest_artifact.py" \
  "$root/baseline/normalized/cargo-metadata.json" "$root/baseline/normalized/binaries.json" "$root/baseline/normalized/tests.json" \
  "$relative_python" "$relative_nextest" >"$tmp/pass.out" 2>&1
grep -F 'adapter relocated sanitized: passed' "$tmp/pass.out" >/dev/null
# A final symlink is rejected at the same production validation boundary.
symlink_dir=$tmp/symlink
mkdir -p "$symlink_dir"
ln -s "$root/$relative_artifact" "$symlink_dir/artifact"
set +e
BUCK_PROJECT_ROOT="$root" ADAPTER_RELOCATED_ARTIFACT_BUCK_OUTPUT_PATH="$symlink_dir/artifact" \
ADAPTER_RELOCATED_MANIFEST_BUCK_OUTPUT_PATH="$manifest" \
ADAPTER_RELOCATED_PYTHON_BUCK_OUTPUT_PATH="$python" \
ADAPTER_RELOCATED_NEXTEST_BUCK_OUTPUT_PATH="$nextest" \
"$root/adapter_relocated_sanitized.sh" "$symlink_dir/artifact" "$manifest" "$root/tools/nextest_artifact.py" \
  "$root/baseline/normalized/cargo-metadata.json" "$root/baseline/normalized/binaries.json" "$root/baseline/normalized/tests.json" \
  "$python" "$nextest" >"$tmp/symlink.out" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
grep -F 'adapter relocated: phase=setup message=Buck output escaped project root' "$tmp/symlink.out" >/dev/null
! grep -F 'top-level cargo nextest dispatch' "$tmp/symlink.out" >/dev/null
printf '%s\n' 'adapter relocated path derivation test: passed'
