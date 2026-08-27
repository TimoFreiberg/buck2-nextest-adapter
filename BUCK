filegroup(
    name = "fixture/Cargo.toml",
    srcs = ["fixture/Cargo.toml"],
)

genrule(
    name = "unsupported_nextest_host",
    out = "unsupported-nextest-host",
    cmd = "echo 'cargo-nextest 0.9.143 supports only Linux x86_64/aarch64 and macOS x86_64/arm64' >&2; exit 1",
)

alias(
    name = "nextest_buck_artifact_runner",
    actual = "//adapter:nextest-buck-artifact",
    visibility = ["PUBLIC"],
)

alias(
    name = "nextest_buck_test_contract_runner",
    actual = "//adapter:nextest-buck-test-contract",
    visibility = ["PUBLIC"],
)

alias(
    name = "nextest_buck_test_runner",
    actual = "//adapter:nextest-buck-test",
    visibility = ["PUBLIC"],
)

alias(
    name = "nextest_v2_executor",
    actual = "//executor:nextest-v2-executor",
    visibility = ["PUBLIC"],
)

filegroup(
    name = "runtime/buck2_artifact_runtime.txt",
    srcs = ["runtime/buck2_artifact_runtime.txt"],
)

genrule(
    name = "nextest-bundle-runtime-resource",
    visibility = ["PUBLIC"],
    out = "nextest-bundle-runtime-resource.txt",
    cmd = "cp runtime/buck2_artifact_runtime.txt $OUT",
    srcs = ["runtime/buck2_artifact_runtime.txt"],
)

genrule(
    name = "runtime_resource",
    out = "runtime/buck2_artifact_runtime.txt",
    cmd = "cp runtime/buck2_artifact_runtime.txt $OUT",
    srcs = ["runtime/buck2_artifact_runtime.txt"],
)

filegroup(
    name = "baseline",
    srcs = [
        "baseline/normalized/cargo-metadata.json",
        "baseline/normalized/binaries.json",
        "baseline/normalized/tests.json",
    ],
    copy = False,
)

genrule(
    name = "cargo_baseline",
    out = "cargo-metadata.json",
    cmd = "cp baseline/normalized/cargo-metadata.json $OUT",
    srcs = ["baseline/normalized/cargo-metadata.json"],
)

genrule(
    name = "binary_baseline",
    out = "binaries.json",
    cmd = "cp baseline/normalized/binaries.json $OUT",
    srcs = ["baseline/normalized/binaries.json"],
)

genrule(
    name = "tests_baseline",
    out = "tests.json",
    cmd = "cp baseline/normalized/tests.json $OUT",
    srcs = ["baseline/normalized/tests.json"],
)

load(":nextest.bzl", "nextest_buck_artifact_junit", "nextest_buck_test", "nextest_buck_test_binary", "nextest_executable")

nextest_executable(
    name = "nextest-cargo-nextest-v1-executable",
    visibility = ["PUBLIC"],
    source = "tools/nextest_cargo_nextest_v1.py",
    out = "nextest-cargo-nextest-v1-executable",
)

nextest_executable(
    name = "nextest-cargo-nextest-v2-executable",
    visibility = ["PUBLIC"],
    source = "tools/nextest_cargo_nextest_v2.py",
    out = "nextest-cargo-nextest-v2-executable",
)

nextest_executable(
    name = "nextest_buck_artifact_junit_signal_fixture",
    source = "tools/nextest_buck_artifact_junit_signal_fixture.py",
    out = "nextest-buck-artifact-junit-signal-fixture",
)

filegroup(
    name = "baseline_summary",
    srcs = ["baseline/normalized/summary.json"],
    copy = False,
)

rust_test(
    name = "buck2_nextest_rust_test",
    srcs = ["buck2_artifact.rs"],
    crate_root = "buck2_artifact.rs",
)

rust_test(
    name = "buck2_nextest_rust_test_beta",
    srcs = ["buck2_artifact.rs"],
    crate_root = "buck2_artifact.rs",
)

rust_test(
    name = "buck2_nextest_rust_test_gamma",
    srcs = ["nextest_v2_fixture.rs"],
    crate_root = "nextest_v2_fixture.rs",
    deps = ["//third-party:serde_json"],
)

rust_test(
    name = "buck2_nextest_v2_rust_test_alpha",
    srcs = ["nextest_v2_fixture.rs"],
    crate_root = "nextest_v2_fixture.rs",
    deps = ["//third-party:serde_json"],
)

rust_test(
    name = "buck2_nextest_v2_rust_test_beta",
    srcs = ["nextest_v2_fixture.rs"],
    crate_root = "nextest_v2_fixture.rs",
    deps = ["//third-party:serde_json"],
)

genrule(
    name = "nextest_generated_rust_runtime_resource",
    out = "nextest-generated-rust-runtime-resource.txt",
    cmd = "printf '%s\\n' 'buck2-nextest-generated-runtime-resource-v1' > $OUT",
)

rust_test(
    name = "buck2_nextest_runtime_resource_positive_executable",
    srcs = ["nextest_runtime_resource_fixture.rs"],
    crate_root = "nextest_runtime_resource_fixture.rs",
    deps = ["//third-party:serde_json"],
    resources = [":nextest_generated_rust_runtime_resource"],
)

rust_test(
    name = "buck2_nextest_runtime_resource_negative_executable",
    srcs = ["nextest_runtime_resource_fixture.rs"],
    crate_root = "nextest_runtime_resource_fixture.rs",
    deps = ["//third-party:serde_json"],
)

genrule(
    name = "buck2_nextest_artifact_manifest",
    out = "artifact-manifest.json",
    cmd = "$(location :nextest_buck_artifact_runner) emit-manifest --artifact $(location :buck2_nextest_rust_test) --runtime-input runtime/buck2_artifact_runtime.txt --runtime-source $(source runtime/buck2_artifact_runtime.txt) --output $OUT",
    srcs = [":buck2_nextest_rust_test", "runtime/buck2_artifact_runtime.txt", ":nextest_buck_artifact_runner"],
)

nextest_buck_artifact_junit(
    name = "nextest_buck_artifact_junit",
)

nextest_buck_artifact_junit(
    name = "nextest_buck_artifact_junit_custom",
    profile = "custom-ci",
    filter = "test(=pass_case)",
)

nextest_buck_artifact_junit(
    name = "nextest_buck_artifact_junit_tool_v1",
    _nextest_toolchain = "toolchains//:nextest-v1",
)

nextest_buck_artifact_junit(
    name = "nextest_buck_artifact_junit_tool_v2",
    _nextest_toolchain = "toolchains//:nextest-v2",
)

nextest_buck_artifact_junit(
    name = "nextest_buck_artifact_junit_expected_failure",
    filter = "test(=fail_case)",
)

genrule(
    name = "nextest_buck_artifact_junit_expected_failure_consumer",
    out = "nextest-buck-artifact-junit-expected-failure-copy.txt",
    cmd = "cp $(location :nextest_buck_artifact_junit_expected_failure) $OUT",
    srcs = [":nextest_buck_artifact_junit_expected_failure"],
)

nextest_buck_test_binary(
    name = "nextest_buck_test_binary_alpha",
    executable = ":buck2_nextest_v2_rust_test_alpha",
    package_identity = "demo-package",
    owner_label = "//:demo_tests",
    binary_identity = "alpha",
    display_name = "same-display-name",
    cwd = "work",
    platform = select({
        "ovr_config//os:linux": select({
            "ovr_config//cpu:x86_64": "x86_64-unknown-linux-gnu",
            "ovr_config//cpu:arm64": "aarch64-unknown-linux-gnu",
            "DEFAULT": "unsupported",
        }),
        "ovr_config//os:macos": select({
            "ovr_config//cpu:x86_64": "x86_64-apple-darwin",
            "ovr_config//cpu:arm64": "aarch64-apple-darwin",
            "DEFAULT": "unsupported",
        }),
        "DEFAULT": "unsupported",
    }),
)

nextest_buck_test_binary(
    name = "nextest_buck_test_binary_beta",
    executable = ":buck2_nextest_v2_rust_test_beta",
    package_identity = "demo-package",
    owner_label = "//:demo_tests",
    binary_identity = "beta",
    display_name = "same-display-name",
    cwd = "work",
    platform = select({
        "ovr_config//os:linux": select({
            "ovr_config//cpu:x86_64": "x86_64-unknown-linux-gnu",
            "ovr_config//cpu:arm64": "aarch64-unknown-linux-gnu",
            "DEFAULT": "unsupported",
        }),
        "ovr_config//os:macos": select({
            "ovr_config//cpu:x86_64": "x86_64-apple-darwin",
            "ovr_config//cpu:arm64": "aarch64-apple-darwin",
            "DEFAULT": "unsupported",
        }),
        "DEFAULT": "unsupported",
    }),
)

nextest_buck_test_binary(
    name = "nextest_buck_test_binary_gamma",
    executable = ":buck2_nextest_rust_test_gamma",
    package_identity = "other-demo-package",
    owner_label = "//:other_demo_tests",
    binary_identity = "gamma",
    display_name = "same-display-name",
    cwd = "other-work",
    platform = select({
        "ovr_config//os:linux": select({
            "ovr_config//cpu:x86_64": "x86_64-unknown-linux-gnu",
            "ovr_config//cpu:arm64": "aarch64-unknown-linux-gnu",
            "DEFAULT": "unsupported",
        }),
        "ovr_config//os:macos": select({
            "ovr_config//cpu:x86_64": "x86_64-apple-darwin",
            "ovr_config//cpu:arm64": "aarch64-apple-darwin",
            "DEFAULT": "unsupported",
        }),
        "DEFAULT": "unsupported",
    }),
)

nextest_buck_test(
    name = "nextest_buck_test_generic_multi_binary",
    records = [":nextest_buck_test_binary_alpha", ":nextest_buck_test_binary_beta", ":nextest_buck_test_binary_gamma"],
    env = {"BUCK2_ARTIFACT_RUNTIME": "declared"},
)

nextest_buck_test_binary(
    name = "nextest_buck_test_binary_runtime_invalid",
    executable = ":nextest-cargo-nextest-v2-executable",
    package_identity = "invalid",
    owner_label = "//:invalid",
    binary_identity = "provider",
    display_name = "invalid",
    cwd = "work",
    platform = "invalid-platform",
)

nextest_buck_test_binary(
    name = "nextest_buck_test_binary_runtime_positive",
    executable = ":buck2_nextest_runtime_resource_positive_executable",
    package_identity = "runtime",
    owner_label = "//:runtime",
    binary_identity = "positive",
    display_name = "provider-runtime-resource",
    cwd = "work",
    platform = select({
        "ovr_config//os:linux": select({
            "ovr_config//cpu:x86_64": "x86_64-unknown-linux-gnu",
            "ovr_config//cpu:arm64": "aarch64-unknown-linux-gnu",
            "DEFAULT": "unsupported",
        }),
        "ovr_config//os:macos": select({
            "ovr_config//cpu:x86_64": "x86_64-apple-darwin",
            "ovr_config//cpu:arm64": "aarch64-apple-darwin",
            "DEFAULT": "unsupported",
        }),
        "DEFAULT": "unsupported",
    }),
)

nextest_buck_test_binary(
    name = "nextest_buck_test_binary_runtime_negative",
    executable = ":buck2_nextest_runtime_resource_negative_executable",
    package_identity = "runtime",
    owner_label = "//:runtime",
    binary_identity = "negative",
    display_name = "provider-runtime-resource",
    cwd = "work",
    platform = select({
        "ovr_config//os:linux": select({
            "ovr_config//cpu:x86_64": "x86_64-unknown-linux-gnu",
            "ovr_config//cpu:arm64": "aarch64-unknown-linux-gnu",
            "DEFAULT": "unsupported",
        }),
        "ovr_config//os:macos": select({
            "ovr_config//cpu:x86_64": "x86_64-apple-darwin",
            "ovr_config//cpu:arm64": "aarch64-apple-darwin",
            "DEFAULT": "unsupported",
        }),
        "DEFAULT": "unsupported",
    }),
)

nextest_buck_test(
    name = "nextest_buck_test_runtime_closure_positive",
    records = [":nextest_buck_test_binary_runtime_positive"],
    filter = "test(=provider_runtime_resource_case)",
)

nextest_buck_test(
    name = "nextest_buck_test_runtime_closure_negative",
    records = [":nextest_buck_test_binary_runtime_negative"],
    filter = "test(=provider_runtime_resource_case)",
)

nextest_buck_test(
    name = "nextest_buck_test_failure",
    records = [":nextest_buck_test_binary_alpha", ":nextest_buck_test_binary_beta", ":nextest_buck_test_binary_gamma"],
    filter = "test(=fail_case)",
    env = {"BUCK2_ARTIFACT_RUNTIME": "declared"},
)

nextest_buck_test(
    name = "nextest_buck_test_ignored",
    records = [":nextest_buck_test_binary_alpha", ":nextest_buck_test_binary_beta", ":nextest_buck_test_binary_gamma"],
    filter = "test(=ignored_case)",
    no_tests = "pass",
    report_skipped = "ignored",
    env = {"BUCK2_ARTIFACT_RUNTIME": "declared"},
)

nextest_buck_test(
    name = "nextest_buck_test_no_tests",
    records = [":nextest_buck_test_binary_alpha", ":nextest_buck_test_binary_beta", ":nextest_buck_test_binary_gamma"],
    filter = "test(=does_not_exist)",
    no_tests = "fail",
    env = {"BUCK2_ARTIFACT_RUNTIME": "declared"},
)

nextest_buck_test(
    name = "nextest_buck_test_timeout",
    records = [":nextest_buck_test_binary_alpha", ":nextest_buck_test_binary_beta", ":nextest_buck_test_binary_gamma"],
    filter = "test(=timeout_case)",
    timeout_seconds = 1,
    env = {"BUCK2_ARTIFACT_RUNTIME": "declared"},
)

nextest_buck_test(
    name = "nextest_buck_test_cancellation",
    records = [":nextest_buck_test_binary_alpha"],
    filter = "test(=cancellation_case)",
    no_tests = "fail",
    env = {"BUCK2_ARTIFACT_RUNTIME": "declared"},
)

sh_test(
    name = "test_semantic_contract",
    test = "tools/test_semantic_contract_rust.sh",
    args = [
        "$(location :nextest_buck_test_contract_runner)",
        "$(location :nextest_buck_test_binary_alpha)",
        "$(location :nextest_buck_test_binary_beta)",
    ],
    resources = [
        "tools/test_semantic_contract_rust.sh",
        ":nextest_buck_test_contract_runner",
        ":nextest_buck_test_binary_alpha",
        ":nextest_buck_test_binary_beta",
    ],
)

sh_test(
    name = "buck2_nextest_runtime_closure_fixture_unit",
    test = "tools/runtime_closure_fixture_unit.py",
    args = [
        "$(location :buck2_nextest_runtime_resource_positive_executable)",
        "$(location :buck2_nextest_runtime_resource_negative_executable)",
    ],
    resources = ["tools/runtime_closure_fixture_unit.py", ":buck2_nextest_runtime_resource_positive_executable", ":buck2_nextest_runtime_resource_negative_executable"],
)

sh_test(
    name = "buck2_nextest_runtime_provider_fixture_contract",
    test = "tools/runtime_provider_fixture_contract.sh",
    args = ["$(location :buck2_nextest_runtime_resource_positive_executable)"],
    resources = ["tools/runtime_provider_fixture_contract.sh", ":buck2_nextest_runtime_resource_positive_executable"],
)

sh_test(
    name = "buck2_nextest_external_test_surface",
    test = "tools/test_external_test_surface.py",
    resources = ["tools/test_external_test_surface.py", "nextest.bzl", "BUCK"],
)

sh_test(
    name = "schema_v2_fixture_contract",
    test = "tools/schema_v2_fixture_contract.sh",
    args = ["$(location :buck2_nextest_v2_rust_test_alpha)"],
    resources = ["tools/schema_v2_fixture_contract.sh", ":buck2_nextest_v2_rust_test_alpha"],
)

sh_test(
    name = "nextest_buck_artifact",
    test = "buck_artifact_scenario.sh",
    args = [
        "$(location :buck2_nextest_rust_test)",
        "$(location :buck2_nextest_artifact_manifest)",
        "$(source tools/nextest_artifact.py)",
        "$(source baseline/normalized/cargo-metadata.json)",
        "$(source baseline/normalized/binaries.json)",
        "$(source baseline/normalized/tests.json)",
    ],
    resources = [":nextest_buck_artifact_runner", "buck_artifact_scenario.sh"],
)

sh_test(
    name = "nextest_buck_artifact_expected_failure",
    test = "buck_artifact_expected_failure_assert.sh",
    args = [
        "$(location :buck2_nextest_rust_test)",
        "$(location :buck2_nextest_artifact_manifest)",
        "$(source tools/nextest_artifact.py)",
        "$(source baseline/normalized/cargo-metadata.json)",
        "$(source baseline/normalized/binaries.json)",
        "$(source baseline/normalized/tests.json)",
    ],
    resources = [":nextest_buck_artifact_runner", "buck_artifact_expected_failure_assert.sh"],
)

sh_test(
    name = "nextest_buck_artifact_real_dispatch",
    test = "buck_artifact_real_dispatch.sh",
    args = [
        "$(location :buck2_nextest_rust_test)",
        "$(location :buck2_nextest_artifact_manifest)",
        "$(source tools/nextest_artifact.py)",
        "$(source baseline/normalized/cargo-metadata.json)",
        "$(source baseline/normalized/binaries.json)",
        "$(source baseline/normalized/tests.json)",
    ],
    resources = [":nextest_buck_artifact_runner", "buck_artifact_real_dispatch.sh"],
)

[
    sh_test(
        name = "nextest_buck_artifact_status_{}".format(scenario),
        test = "buck_artifact_status.sh",
        args = [
            scenario,
            "$(location :buck2_nextest_rust_test)",
            "$(location :buck2_nextest_artifact_manifest)",
            "$(source tools/nextest_artifact.py)",
            "$(source baseline/normalized/cargo-metadata.json)",
            "$(source baseline/normalized/binaries.json)",
            "$(source baseline/normalized/tests.json)",
        ],
        resources = [":nextest_buck_artifact_runner", "buck_artifact_status.sh"],
    )
    for scenario in ["ignored", "filtered", "no-tests", "no-tests-auto", "timeout", "timeout-disabled"]
]

[
    sh_test(
        name = "nextest_buck_artifact_report_{}".format(subcase),
        test = "buck_artifact_report_destination.sh",
        args = [
            subcase,
            "$(location :buck2_nextest_rust_test)",
            "$(location :buck2_nextest_artifact_manifest)",
            "$(source tools/nextest_artifact.py)",
            "$(source baseline/normalized/cargo-metadata.json)",
            "$(source baseline/normalized/binaries.json)",
            "$(source baseline/normalized/tests.json)",
        ],
        resources = [
            ":nextest_buck_artifact_runner",
            "buck_artifact_report_destination.sh",
            "buck_artifact_export_fault.sh",
        ],
    )
    for subcase in ["pre-dispatch", "success-export-failure", "failure-export-failure", "malformed-report", "list-failure", "timeout-capture", "permission"]
]

sh_test(
    name = "nextest_buck_artifact_manifest_mutation",
    test = "buck_artifact_manifest_mutation.sh",
    args = [
        "$(location :buck2_nextest_rust_test)",
        "$(location :buck2_nextest_artifact_manifest)",
        "$(source tools/nextest_artifact.py)",
        "$(source baseline/normalized/cargo-metadata.json)",
        "$(source baseline/normalized/binaries.json)",
        "$(source baseline/normalized/tests.json)",
    ],
    resources = [":nextest_buck_artifact_runner", "buck_artifact_manifest_mutation.sh"],
)

sh_test(
    name = "nextest_buck_artifact_invalid_manifest",
    test = "buck_artifact_invalid_manifest.sh",
    args = [
        "$(location :buck2_nextest_rust_test)",
        "$(location :buck2_nextest_artifact_manifest)",
        "$(source tools/nextest_artifact.py)",
        "$(source baseline/normalized/cargo-metadata.json)",
        "$(source baseline/normalized/binaries.json)",
        "$(source baseline/normalized/tests.json)",
    ],
    resources = [":nextest_buck_artifact_runner", "buck_artifact_invalid_manifest.sh"],
)

sh_test(
    name = "nextest_buck_artifact_metadata",
    test = "buck_artifact_metadata.sh",
    args = [
        "$(location :buck2_nextest_rust_test)",
        "$(location :buck2_nextest_artifact_manifest)",
        "$(source tools/nextest_artifact.py)",
        "$(source baseline/normalized/cargo-metadata.json)",
        "$(source baseline/normalized/binaries.json)",
        "$(source baseline/normalized/tests.json)",
        "$(source baseline/normalized/summary.json)",
    ],
    resources = [
        "buck_artifact_metadata.sh",
        "runtime/buck2_artifact_runtime.txt",
        ":baseline",
        ":baseline_summary",
    ],
)

sh_test(
    name = "validate_artifact_manifest",
    test = "validate_manifest_cases.sh",
    args = [
        "$(location :buck2_nextest_rust_test)",
        "$(source tools/manifest-input.json)",
        "$(location :buck2_nextest_artifact_manifest)",
    ],
    resources = [
        "artifact-manifest.example.json",
        "tools/manifest-input.json",
        "tools/nextest_artifact.py",
        ":buck2_nextest_artifact_manifest",
    ],
)

sh_test(
    name = "adapter_bundle_validation",
    test = "adapter_bundle_validation.sh",
    args = [
        "$(location :buck2_nextest_rust_test)",
        "$(location :buck2_nextest_artifact_manifest)",
        "$(source tools/nextest_artifact.py)",
        "$(source baseline/normalized/cargo-metadata.json)",
        "$(source baseline/normalized/binaries.json)",
        "$(source baseline/normalized/tests.json)",
    ],
    resources = [
        ":nextest_buck_artifact_runner",
        "adapter_bundle_validation.sh",
        "runtime/buck2_artifact_runtime.txt",
    ],
)

sh_test(
    name = "adapter_mode_validation",
    test = "adapter_mode_validation.sh",
    args = [
        "$(location :buck2_nextest_rust_test)",
        "$(location :buck2_nextest_artifact_manifest)",
        "$(source tools/nextest_artifact.py)",
        "$(source baseline/normalized/cargo-metadata.json)",
        "$(source baseline/normalized/binaries.json)",
        "$(source baseline/normalized/tests.json)",
    ],
    resources = [":nextest_buck_artifact_runner", "adapter_mode_validation.sh"],
)

sh_test(
    name = "adapter_process_group_validation",
    test = "adapter_process_group_validation.sh",
    args = [
        "$(location :buck2_nextest_rust_test)",
        "$(location :buck2_nextest_artifact_manifest)",
        "$(source tools/nextest_artifact.py)",
        "$(source baseline/normalized/cargo-metadata.json)",
        "$(source baseline/normalized/binaries.json)",
        "$(source baseline/normalized/tests.json)",
    ],
    resources = [
        ":nextest_buck_artifact_runner",
        "adapter_process_group_validation.sh",
        "runtime/buck2_artifact_runtime.txt",
    ],
)

sh_test(
    name = "nextest_buck_artifact_bundle_contract",
    test = "nextest_buck_artifact_bundle_contract.sh",
    resources = ["nextest_buck_artifact_bundle_contract.sh"],
)

sh_test(
    name = "nextest_buck_artifact_action_metadata_check",
    test = "nextest_buck_artifact_action_metadata.sh",
    resources = ["nextest_buck_artifact_action_metadata.sh"],
)

sh_test(
    name = "nextest_buck_artifact_rule_contract", 
    test = "nextest_buck_artifact_rule_contract.sh",
    args = ["$(source nextest.bzl)"],
    resources = ["nextest.bzl", "nextest_buck_artifact_rule_contract.sh"],
)

sh_test(
    name = "nextest_buck_artifact_configured",
    test = "nextest_buck_artifact_configured.sh",
    args = [
        "$(location :buck2_nextest_rust_test)",
        "$(location :buck2_nextest_artifact_manifest)",
        "$(source tools/nextest_artifact.py)",
        "$(source baseline/normalized/cargo-metadata.json)",
        "$(source baseline/normalized/binaries.json)",
        "$(source baseline/normalized/tests.json)",
    ],
    resources = [
        "nextest_buck_artifact_configured.sh",
        "runtime/buck2_artifact_runtime.txt",
        ":nextest_buck_artifact_runner",
    ],
)

sh_test(
    name = "nextest_buck_artifact_concurrent",
    test = "nextest_buck_artifact_concurrent.sh",
    args = [
        "$(location :buck2_nextest_rust_test)",
        "$(location :buck2_nextest_artifact_manifest)",
        "$(source tools/nextest_artifact.py)",
        "$(source baseline/normalized/cargo-metadata.json)",
        "$(source baseline/normalized/binaries.json)",
        "$(source baseline/normalized/tests.json)",
    ],
    resources = [
        "nextest_buck_artifact_concurrent.sh",
        "runtime/buck2_artifact_runtime.txt",
        ":nextest_buck_artifact_runner",
    ],
)

sh_test(
    name = "scenario_removed",
    test = "scenario_removed.sh",
    resources = ["scenario_removed.sh", "README.md", "BUCK"],
)

sh_test(
    name = "legacy_path_absent",
    test = "legacy_path_absent.sh",
    resources = [
        "BUCK",
        "fixture/Cargo.toml",
        "tools/capture_cargo_nextest_baseline.sh",
    ],
)

sh_test(
    name = "documentation_smoke",
    test = "docs/smoke_documentation.sh",
    resources = [
        "README.md",
        "BUCK",
        "Justfile",
        "docs/baseline-and-manifest.md",
        "docs/nextest-buck2-roadmap.md",
        "docs/roadmap-follow-ups.md",
        "docs/test-coverage-follow-up.md",
        "legacy_path_absent.sh",
        "nextest_buck_artifact_consumer_inspection.py",
        "nextest_buck_artifact_junit_local.sh",
        "nextest_buck_artifact_remote.sh",
        "nextest_buck_artifact_remote_selftest.sh",
        "nextest_buck_artifact_rule_contract.sh",
        "nextest.bzl",
        "tools/parse_buck_freshness_events.py",
        "tools/test_external_test_surface.py",
        "tools/test_semantic_contract.py",
        "buck2_nextest_runtime_provider_contract.py",
        "nextest_buck_test_relocated_sanitized.sh",
        "buck2_nextest_runtime_closure.sh",
        "tools/runtime_provider_fixture_contract.sh",
        "scenario_removed.sh",
    ],
)

sh_test(
    name = "repository_hygiene",
    test = "repository_hygiene.sh",
    resources = ["repository_hygiene.sh"],
)

sh_test(
    name = "executor_generated_protocol_clean",
    test = "executor_generated_protocol_clean.sh",
    resources = ["executor_generated_protocol_clean.sh"],
)

sh_test(
    name = "executor_rejects_unsupported_invocation",
    test = "executor_rejects_unsupported_invocation.sh",
    args = ["$(location :nextest_v2_executor)"],
    resources = ["executor_rejects_unsupported_invocation.sh", ":nextest_v2_executor"],
)

sh_test(
    name = "adapter_signal_cleanup",
    test = "adapter_signal_cleanup.sh",
)

sh_test(
    name = "nextest_buck_artifact_junit_output",
    test = "nextest_buck_artifact_junit_output.sh",
    args = ["$(location :nextest_buck_artifact_junit)"],
    resources = ["nextest_buck_artifact_junit_output.sh", ":nextest_buck_artifact_junit"],
)

sh_test(
    name = "nextest_buck_artifact_junit_lifecycle",
    test = "nextest_buck_artifact_junit_lifecycle.sh",
    args = ["$(location :nextest_buck_artifact_junit)"],
    resources = ["nextest_buck_artifact_junit_lifecycle.sh", ":nextest_buck_artifact_junit"],
)

sh_test(
    name = "nextest_buck_artifact_junit_outputs",
    test = "nextest_buck_artifact_junit_outputs.sh",
    args = ["$(location :nextest_buck_artifact_junit)", "$(location :nextest_buck_artifact_junit_custom)"],
    resources = ["nextest_buck_artifact_junit_outputs.sh", ":nextest_buck_artifact_junit", ":nextest_buck_artifact_junit_custom"],
)

sh_test(
    name = "nextest_buck_artifact_junit_toolchain",
    test = "nextest_buck_artifact_junit_toolchain.sh",
    args = ["$(location :nextest_buck_artifact_junit)"],
    resources = ["nextest_buck_artifact_junit_toolchain.sh", ":nextest_buck_artifact_junit", "nextest.bzl"],
)

sh_test(
    name = "nextest_capability_preflight",
    test = "nextest_capability_preflight.sh",
    resources = ["nextest_capability_preflight.sh"],
)

# The capability probe and positive signal test are intentionally opt-in. Run
# the positive target only after the probe reports process-group=available.
sh_test(
    name = "nextest_process_group_capability",
    test = "nextest_process_group_capability.sh",
    resources = ["nextest_process_group_capability.sh"],
)

sh_test(
    name = "nextest_buck_artifact_junit_signal",
    test = "nextest_buck_artifact_junit_signal.sh",
    args = [
        "$(location :nextest_buck_artifact_runner)",
        "$(location :nextest_buck_artifact_junit_signal_fixture)",
        "$(location :buck2_nextest_rust_test)",
        "$(location :buck2_nextest_artifact_manifest)",
        "$(source baseline/normalized/cargo-metadata.json)",
        "$(source baseline/normalized/binaries.json)",
        "$(source baseline/normalized/tests.json)",
        "$(source runtime/buck2_artifact_runtime.txt)",
    ],
    resources = ["nextest_buck_artifact_junit_signal.sh", ":nextest_buck_artifact_junit_signal_fixture", ":nextest_buck_artifact_runner", "tools/nextest_cargo_nextest_v1.py", "runtime/buck2_artifact_runtime.txt", ":baseline", ":buck2_nextest_artifact_manifest"],
)
