filegroup(
    name = "fixture/Cargo.toml",
    srcs = ["fixture/Cargo.toml"],
)

filegroup(
    name = "tools",
    srcs = ["tools/nextest_artifact.py", "tools/cargo_source_denial.sh"],
    copy = False,
)

filegroup(
    name = "validator",
    srcs = ["tools/nextest_artifact.py"],
    copy = False,
)

genrule(
    name = "validator_file",
    out = "nextest_artifact.py",
    cmd = "cp tools/nextest_artifact.py $OUT",
    srcs = ["tools/nextest_artifact.py"],
)

genrule(
    name = "source_denial",
    out = "cargo_source_denial.sh",
    cmd = "cp tools/cargo_source_denial.sh $OUT && chmod +x $OUT",
    srcs = ["tools/cargo_source_denial.sh"],
)

filegroup(
    name = "runtime/buck2_artifact_runtime.txt",
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

load(":nextest.bzl", "nextest_buck_artifact_junit")

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

genrule(
    name = "buck2_nextest_artifact_manifest",
    out = "artifact-manifest.json",
    cmd = "python3 $(source tools/nextest_artifact.py) emit-manifest --artifact $(location :buck2_nextest_rust_test) --runtime-input runtime/buck2_artifact_runtime.txt --runtime-source $(source runtime/buck2_artifact_runtime.txt) --output $OUT",
    srcs = ["tools/nextest_artifact.py", ":buck2_nextest_rust_test", "runtime/buck2_artifact_runtime.txt"],
)

nextest_buck_artifact_junit(
    name = "nextest_buck_artifact_junit",
)

nextest_buck_artifact_junit(
    name = "nextest_buck_artifact_junit_custom",
    profile = "custom-ci",
    filter = "test(=pass_case)",
)

sh_binary(
    name = "nextest_buck_artifact_runner",
    main = "adapter.sh",
    append_script_extension = False,
    resources = [
        ":buck2_nextest_rust_test",
        ":buck2_nextest_artifact_manifest",
        "runtime/buck2_artifact_runtime.txt",
        "tools/nextest_artifact.py",
        "tools/cargo_source_denial.sh",
        ":baseline",
    ],
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
    for scenario in ["ignored", "filtered", "no-tests", "timeout"]
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
    for subcase in ["pre-dispatch", "success-export-failure", "failure-export-failure", "malformed-report", "list-failure", "timeout-capture"]
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
    name = "adapter_mode_validation",
    test = "adapter_mode_validation.sh",
    resources = ["adapter.sh"],
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
        "nextest_test_recorder.py",
        "runtime/buck2_artifact_runtime.txt",
        "tools/cargo_source_denial.sh",
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
        "nextest_test_recorder.py",
        "runtime/buck2_artifact_runtime.txt",
        "tools/cargo_source_denial.sh",
        ":nextest_buck_artifact_runner",
    ],
)

sh_test(
    name = "scenario_removed",
    test = "scenario_removed.sh",
    resources = ["scenario_removed.sh", "adapter.sh", "README.md", "BUCK"],
)

sh_test(
    name = "legacy_path_absent",
    test = "legacy_path_absent.sh",
    resources = [
        "adapter.sh",
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
        "docs/baseline-and-manifest.md",
        "docs/nextest-buck2-roadmap.md",
    ],
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

sh_test(
    name = "nextest_buck_artifact_junit_signal",
    test = "nextest_buck_artifact_junit_signal.sh",
)
