set shell := ["bash", "-euo", "pipefail", "-c"]

# Run every repository check, including the repository-level Buck action inspection.
ci: _buck-ci nextest_buck_artifact_action_inspection nextest_buck_artifact_consumer_inspection nextest_buck_artifact_action_metadata_check nextest_buck_artifact_junit_materialization nextest_buck_artifact_junit_local nextest_buck_artifact_junit_failure nextest_buck_artifact_junit_action_key nextest_buck_artifact_junit_cache nextest_buck_artifact_junit_concurrent_buck

# Run the Buck-backed test suite from the repository shell.
_buck-ci:
    buck2 test --test-executor-stdout=- --test-executor-stderr=- \
        //:adapter_mode_validation \
        //:adapter_process_group_validation \
        //:adapter_signal_cleanup \
        //:documentation_smoke \
        //:legacy_path_absent \
        //:nextest_buck_artifact \
        //:nextest_buck_artifact_concurrent \
        //:nextest_buck_artifact_configured \
        //:nextest_buck_artifact_expected_failure \
        //:nextest_buck_artifact_invalid_manifest \
        //:nextest_buck_artifact_real_dispatch \
        //:nextest_buck_artifact_junit_lifecycle \
        //:nextest_buck_artifact_junit_output \
        //:nextest_buck_artifact_junit_outputs \
        //:nextest_buck_artifact_junit_signal \
        //:nextest_buck_artifact_junit_toolchain \
        //:nextest_buck_artifact_manifest_mutation \
        //:nextest_buck_artifact_metadata \
        //:nextest_buck_artifact_report_failure-export-failure \
        //:nextest_buck_artifact_report_list-failure \
        //:nextest_buck_artifact_report_malformed-report \
        //:nextest_buck_artifact_report_pre-dispatch \
        //:nextest_buck_artifact_report_success-export-failure \
        //:nextest_buck_artifact_report_timeout-capture \
        //:nextest_buck_artifact_report_permission \
        //:nextest_buck_artifact_rule_contract \
        //:nextest_buck_artifact_status_filtered \
        //:nextest_buck_artifact_status_ignored \
        //:nextest_buck_artifact_status_no-tests \
        //:nextest_buck_artifact_status_no-tests-auto \
        //:nextest_buck_artifact_status_timeout \
        //:nextest_buck_artifact_status_timeout-disabled \
        //:nextest_capability_preflight \
        //:scenario_removed \
        //:validate_artifact_manifest

# Run the repository-level action graph inspection without nesting Buck in sh_test.
nextest_buck_artifact_action_inspection:
    python3 nextest_buck_artifact_action_inspection.py buck2 "$(pwd -P)"
nextest_buck_artifact_action_metadata:
    ./nextest_buck_artifact_action_metadata.sh
nextest_buck_artifact_junit_materialization:
    ./nextest_buck_artifact_junit_materialization.sh
nextest_buck_artifact_junit_local:
    ./nextest_buck_artifact_junit_local.sh
nextest_buck_artifact_remote:
    ./nextest_buck_artifact_remote.sh
nextest_buck_artifact_remote_selftest:
    ./nextest_buck_artifact_remote_selftest.sh

# Verify the declared consumer graph without nesting Buck in sh_test.
nextest_buck_artifact_consumer_inspection:
    python3 nextest_buck_artifact_consumer_inspection.py buck2 "$(pwd -P)"

# Verify failed declared-output and consumer semantics from the repository shell.
nextest_buck_artifact_junit_failure:
    ./nextest_buck_artifact_junit_failure.sh
nextest_buck_artifact_junit_action_key:
    ./nextest_buck_artifact_junit_action_key.sh
nextest_buck_artifact_junit_cache:
    ./nextest_buck_artifact_junit_cache.sh
nextest_buck_artifact_junit_concurrent_buck:
    ./nextest_buck_artifact_junit_concurrent_buck.sh

# Run one Buck-backed test by its Buck target name, for example `just nextest_buck_artifact_configured`.
_buck-test name:
    buck2 test --test-executor-stdout=- --test-executor-stderr=- "//:{{name}}"

# These portability harnesses remain repository-level checks because this Buck
# executor does not surface their diagnostics reliably through sh_test.
adapter_direct_scratch_fallback:
    root=$(pwd -P) && \
    artifact=$(buck2 build --show-output //:buck2_nextest_rust_test | tail -1 | cut -d' ' -f2) && \
    manifest=$(buck2 build --show-output //:buck2_nextest_artifact_manifest | tail -1 | cut -d' ' -f2) && \
    ./adapter_direct_scratch_fallback.sh "$artifact" "$manifest" "$root/tools/nextest_artifact.py" "$root/baseline/normalized/cargo-metadata.json" "$root/baseline/normalized/binaries.json" "$root/baseline/normalized/tests.json"
adapter_relocated_sanitized:
    root=$(pwd -P) && \
    artifact="$root/$(buck2 build --show-output //:buck2_nextest_rust_test | tail -1 | cut -d' ' -f2)" && \
    manifest="$root/$(buck2 build --show-output //:buck2_nextest_artifact_manifest | tail -1 | cut -d' ' -f2)" && \
    python=$(realpath "$root/$(buck2 build --show-output //:nextest-python-executable | tail -1 | cut -d' ' -f2)") && \
    nextest=$(realpath "$root/$(buck2 build --show-output //:nextest-cargo-nextest-v1-executable | tail -1 | cut -d' ' -f2)") && \
    ./adapter_relocated_sanitized.sh "$artifact" "$manifest" "$root/tools/nextest_artifact.py" "$root/baseline/normalized/cargo-metadata.json" "$root/baseline/normalized/binaries.json" "$root/baseline/normalized/tests.json" "$python" "$nextest"
adapter_mode_validation:
    just _buck-test adapter_mode_validation
adapter_process_group_validation:
    just _buck-test adapter_process_group_validation
adapter_signal_cleanup:
    just _buck-test adapter_signal_cleanup
documentation_smoke:
    just _buck-test documentation_smoke
legacy_path_absent:
    just _buck-test legacy_path_absent
nextest_buck_artifact:
    just _buck-test nextest_buck_artifact
nextest_buck_artifact_concurrent:
    just _buck-test nextest_buck_artifact_concurrent
nextest_buck_artifact_configured:
    just _buck-test nextest_buck_artifact_configured
nextest_buck_artifact_expected_failure:
    just _buck-test nextest_buck_artifact_expected_failure
nextest_buck_artifact_invalid_manifest:
    just _buck-test nextest_buck_artifact_invalid_manifest
nextest_buck_artifact_real_dispatch:
    just _buck-test nextest_buck_artifact_real_dispatch
nextest_buck_artifact_junit_lifecycle:
    just _buck-test nextest_buck_artifact_junit_lifecycle
nextest_buck_artifact_action_metadata_check:
    just _buck-test nextest_buck_artifact_action_metadata_check
nextest_buck_artifact_junit_output:
    just _buck-test nextest_buck_artifact_junit_output
nextest_buck_artifact_junit_outputs:
    just _buck-test nextest_buck_artifact_junit_outputs
nextest_buck_artifact_junit_signal:
    just _buck-test nextest_buck_artifact_junit_signal
nextest_buck_artifact_junit_toolchain:
    just _buck-test nextest_buck_artifact_junit_toolchain
nextest_buck_artifact_manifest_mutation:
    just _buck-test nextest_buck_artifact_manifest_mutation
nextest_buck_artifact_metadata:
    just _buck-test nextest_buck_artifact_metadata
nextest_buck_artifact_report_failure-export-failure:
    just _buck-test nextest_buck_artifact_report_failure-export-failure
nextest_buck_artifact_report_list-failure:
    just _buck-test nextest_buck_artifact_report_list-failure
nextest_buck_artifact_report_malformed-report:
    just _buck-test nextest_buck_artifact_report_malformed-report
nextest_buck_artifact_report_pre-dispatch:
    just _buck-test nextest_buck_artifact_report_pre-dispatch
nextest_buck_artifact_report_success-export-failure:
    just _buck-test nextest_buck_artifact_report_success-export-failure
nextest_buck_artifact_report_timeout-capture:
    just _buck-test nextest_buck_artifact_report_timeout-capture
nextest_buck_artifact_report_permission:
    just _buck-test nextest_buck_artifact_report_permission
nextest_buck_artifact_rule_contract:
    just _buck-test nextest_buck_artifact_rule_contract
nextest_buck_artifact_status_filtered:
    just _buck-test nextest_buck_artifact_status_filtered
nextest_buck_artifact_status_ignored:
    just _buck-test nextest_buck_artifact_status_ignored
nextest_buck_artifact_status_no-tests:
    just _buck-test nextest_buck_artifact_status_no-tests
nextest_buck_artifact_status_no-tests-auto:
    just _buck-test nextest_buck_artifact_status_no-tests-auto
nextest_buck_artifact_status_timeout:
    just _buck-test nextest_buck_artifact_status_timeout
nextest_buck_artifact_status_timeout-disabled:
    just _buck-test nextest_buck_artifact_status_timeout-disabled
nextest_capability_preflight:
    just _buck-test nextest_capability_preflight
scenario_removed:
    just _buck-test scenario_removed
validate_artifact_manifest:
    just _buck-test validate_artifact_manifest
