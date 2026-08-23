#!/bin/sh
set -eu
root=${BUCK_PROJECT_ROOT:-$(cd "$(dirname "$0")" && pwd -P)}
# Static graph assertions are intentionally simple and stable: every CI-only
# Buck-bearing wrapper is directly gated, while generic _buck-test is not.
for wrapper in _buck-ci _ci-nextest_buck_artifact_action_inspection _ci-nextest_buck_artifact_consumer_inspection _ci-nextest_buck_artifact_action_metadata _ci-nextest_buck_artifact_action_metadata_check _ci-nextest_buck_artifact_junit_materialization _ci-nextest_buck_artifact_junit_local _ci-nextest_buck_artifact_junit_failure _ci-nextest_buck_artifact_junit_action_key _ci-nextest_buck_artifact_junit_cache _ci-nextest_buck_artifact_junit_concurrent_buck _ci-adapter_relocated_sanitized; do
    grep -E "^${wrapper}:.*_relocation-preflight([[:space:]]|$)" "$root/Justfile" >/dev/null || { printf 'missing direct preflight edge=%s\n' "$wrapper" >&2; exit 1; }
done
awk '/^_buck-test name:/{found=1; next} found && /^[^[:space:]]/{exit} found && /_relocation-preflight/{exit 1}' "$root/Justfile"
printf '%s\n' 'adapter relocated CI order test: passed'
