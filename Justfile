set shell := ["bash", "-euo", "pipefail", "-c"]

project_root := justfile_directory()
buck := env_var_or_default("BUCK2", "buck2")

# Run every repository check, including the repository-level Buck action inspection.
ci: repository_hygiene _relocation-preflight _buck-ci _ci-nextest_buck_artifact_action_inspection _ci-nextest_buck_artifact_consumer_inspection _ci-nextest_buck_artifact_action_metadata _ci-nextest_buck_artifact_action_metadata_check _ci-nextest_buck_artifact_junit_materialization _ci-nextest_buck_artifact_junit_local _ci-nextest_buck_artifact_junit_failure _ci-nextest_buck_artifact_junit_action_key _ci-nextest_buck_artifact_junit_cache _ci-nextest_buck_artifact_junit_concurrent_buck _ci-adapter_relocated_sanitized

_relocation-preflight:
    BUCK2={{buck}} BUCK_PROJECT_ROOT={{project_root}} sh {{project_root}}/adapter_relocated_preflight.sh {{project_root}}

# Run the Buck-backed test suite from the repository shell.
_buck-ci: _relocation-preflight
    BUCK2={{buck}} BUCK_PROJECT_ROOT={{project_root}} {{buck}} test --test-executor-stdout=- --test-executor-stderr=- \
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
        //:repository_hygiene \
        //:scenario_removed \
        //:validate_artifact_manifest

# Run the repository-level action graph inspection without nesting Buck in sh_test.
nextest_buck_artifact_action_inspection:
    BUCK2={{buck}} BUCK_PROJECT_ROOT={{project_root}} {{project_root}}/nextest_buck_artifact_action_inspection.py {{buck}} {{project_root}}
nextest_buck_artifact_action_metadata:
    BUCK2={{buck}} BUCK_PROJECT_ROOT={{project_root}} {{project_root}}/nextest_buck_artifact_action_metadata.sh
nextest_buck_artifact_junit_materialization:
    BUCK2={{buck}} BUCK_PROJECT_ROOT={{project_root}} {{project_root}}/nextest_buck_artifact_junit_materialization.sh
nextest_buck_artifact_junit_local:
    BUCK2={{buck}} BUCK_PROJECT_ROOT={{project_root}} {{project_root}}/nextest_buck_artifact_junit_local.sh
nextest_buck_artifact_remote:
    ./nextest_buck_artifact_remote.sh
nextest_buck_artifact_remote_selftest:
    ./nextest_buck_artifact_remote_selftest.sh

# Verify the declared consumer graph without nesting Buck in sh_test.
nextest_buck_artifact_consumer_inspection:
    BUCK2={{buck}} BUCK_PROJECT_ROOT={{project_root}} {{project_root}}/nextest_buck_artifact_consumer_inspection.py {{buck}} {{project_root}}

# Verify failed declared-output and consumer semantics from the repository shell.
nextest_buck_artifact_junit_failure:
    BUCK2={{buck}} BUCK_PROJECT_ROOT={{project_root}} {{project_root}}/nextest_buck_artifact_junit_failure.sh
nextest_buck_artifact_junit_action_key:
    BUCK2={{buck}} BUCK_PROJECT_ROOT={{project_root}} {{project_root}}/nextest_buck_artifact_junit_action_key.sh
nextest_buck_artifact_junit_cache:
    BUCK2={{buck}} BUCK_PROJECT_ROOT={{project_root}} {{project_root}}/nextest_buck_artifact_junit_cache.sh
nextest_buck_artifact_junit_concurrent_buck:
    BUCK2={{buck}} BUCK_PROJECT_ROOT={{project_root}} {{project_root}}/nextest_buck_artifact_junit_concurrent_buck.sh

# Repository hygiene is both a direct CI prerequisite and a registered Buck test.
repository_hygiene:
    BUCK_PROJECT_ROOT={{project_root}} sh {{project_root}}/repository_hygiene.sh

# Run one Buck-backed test by its Buck target name, for example `just nextest_buck_artifact_configured`.
_buck-test name:
    BUCK2={{buck}} BUCK_PROJECT_ROOT={{project_root}} {{buck}} test --test-executor-stdout=- --test-executor-stderr=- "//:{{name}}"

# CI-only wrappers put the relocation assurance before each Buck-bearing recipe.
_ci-nextest_buck_artifact_action_inspection: _relocation-preflight
    just nextest_buck_artifact_action_inspection
_ci-nextest_buck_artifact_consumer_inspection: _relocation-preflight
    just nextest_buck_artifact_consumer_inspection
_ci-nextest_buck_artifact_action_metadata: _relocation-preflight
    just nextest_buck_artifact_action_metadata
_ci-nextest_buck_artifact_action_metadata_check: _relocation-preflight
    just _buck-test nextest_buck_artifact_action_metadata_check
_ci-nextest_buck_artifact_junit_materialization: _relocation-preflight
    just nextest_buck_artifact_junit_materialization
_ci-nextest_buck_artifact_junit_local: _relocation-preflight
    just nextest_buck_artifact_junit_local
_ci-nextest_buck_artifact_junit_failure: _relocation-preflight
    just nextest_buck_artifact_junit_failure
_ci-nextest_buck_artifact_junit_action_key: _relocation-preflight
    just nextest_buck_artifact_junit_action_key
_ci-nextest_buck_artifact_junit_cache: _relocation-preflight
    just nextest_buck_artifact_junit_cache
_ci-nextest_buck_artifact_junit_concurrent_buck: _relocation-preflight
    just nextest_buck_artifact_junit_concurrent_buck
_ci-adapter_relocated_sanitized: _relocation-preflight
    just adapter_relocated_sanitized

# These portability harnesses remain repository-level checks because this Buck
# executor does not surface their diagnostics reliably through sh_test.
adapter_direct_scratch_fallback:
    BUCK2={{buck}} BUCK_PROJECT_ROOT={{project_root}} {{project_root}}/adapter_direct_scratch_fallback.sh "$({{buck}} build --show-output //:buck2_nextest_rust_test | tail -1 | cut -d' ' -f2)" "$({{buck}} build --show-output //:buck2_nextest_artifact_manifest | tail -1 | cut -d' ' -f2)" "{{project_root}}/tools/nextest_artifact.py" "{{project_root}}/baseline/normalized/cargo-metadata.json" "{{project_root}}/baseline/normalized/binaries.json" "{{project_root}}/baseline/normalized/tests.json"
adapter_relocated_sanitized:
    BUCK2={{buck}} BUCK_PROJECT_ROOT={{project_root}} sh {{project_root}}/adapter_relocated_preflight.sh {{project_root}} && \
    artifact=$({{buck}} build --show-output //:buck2_nextest_rust_test | tail -1 | cut -d' ' -f2) && \
    manifest=$({{buck}} build --show-output //:buck2_nextest_artifact_manifest | tail -1 | cut -d' ' -f2) && \
    python=$({{buck}} build --show-output //:nextest-python-executable | tail -1 | cut -d' ' -f2) && \
    nextest=$({{buck}} build --show-output //:nextest-cargo-nextest-v1-executable | tail -1 | cut -d' ' -f2) && \
    ADAPTER_RELOCATED_ARTIFACT_BUCK_OUTPUT_PATH="$artifact" ADAPTER_RELOCATED_MANIFEST_BUCK_OUTPUT_PATH="$manifest" ADAPTER_RELOCATED_PYTHON_BUCK_OUTPUT_PATH="$python" ADAPTER_RELOCATED_NEXTEST_BUCK_OUTPUT_PATH="$nextest" \
    {{project_root}}/adapter_relocated_sanitized.sh "$artifact" "$manifest" "{{project_root}}/tools/nextest_artifact.py" "{{project_root}}/baseline/normalized/cargo-metadata.json" "{{project_root}}/baseline/normalized/binaries.json" "{{project_root}}/baseline/normalized/tests.json" "$python" "$nextest"
adapter_relocated_preflight_test:
    BUCK_PROJECT_ROOT={{project_root}} sh {{project_root}}/adapter_relocated_preflight_test.sh
adapter_relocated_ci_failure_propagation_test:
    BUCK_PROJECT_ROOT={{project_root}} sh {{project_root}}/adapter_relocated_ci_failure_propagation_test.sh
adapter_relocated_ci_order_test:
    BUCK_PROJECT_ROOT={{project_root}} sh {{project_root}}/adapter_relocated_ci_order_test.sh
adapter_relocated_path_derivation_test:
    BUCK_PROJECT_ROOT={{project_root}} sh {{project_root}}/adapter_relocated_path_derivation_test.sh
adapter_relocated_record_merge_test:
    BUCK_PROJECT_ROOT={{project_root}} sh {{project_root}}/adapter_relocated_record_merge_test.sh
adapter_relocated_failure_test:
    BUCK_PROJECT_ROOT={{project_root}} sh {{project_root}}/adapter_relocated_failure_test.sh adapter
adapter_relocated_setup_failure_test:
    BUCK_PROJECT_ROOT={{project_root}} sh {{project_root}}/adapter_relocated_failure_test.sh setup
adapter_relocated_postrun_failure_test:
    BUCK_PROJECT_ROOT={{project_root}} sh {{project_root}}/adapter_relocated_failure_test.sh postrun
adapter_relocated_cleanup_failure_test:
    BUCK_PROJECT_ROOT={{project_root}} sh {{project_root}}/adapter_relocated_failure_test.sh cleanup
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
