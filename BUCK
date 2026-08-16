filegroup(
    name = "fixture/Cargo.toml",
    srcs = ["fixture/Cargo.toml"],
)

filegroup(
    name = "tools",
    srcs = ["tools/nextest_artifact.py"],
)

filegroup(
    name = "runtime/buck2_artifact_runtime.txt",
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

sh_binary(
    name = "nextest_spike_probe_runner",
    main = "probe.sh",
    append_script_extension = False,
    resources = [
        "fixture/Cargo.toml",
        "fixture/Cargo.lock",
        "fixture/src/lib.rs",
        "fixture/tests/pass_case.rs",
        "fixture/tests/fail_case.rs",
    ],
)

sh_test(
    name = "nextest_spike_probe",
    test = ":nextest_spike_probe_runner",
)

sh_binary(
    name = "nextest_adapter",
    main = "adapter.sh",
    append_script_extension = False,
    resources = [
        "fixture/Cargo.toml",
        "fixture/Cargo.lock",
        "fixture/src/lib.rs",
        "fixture/tests/pass_case.rs",
        "fixture/tests/fail_case.rs",
    ],
)

# The legacy Cargo-owned regression path.
sh_test(
    name = "nextest_spike",
    test = ":nextest_adapter",
    args = [
        "cargo-fixture",
        "--manifest-path",
        "$(source fixture/Cargo.toml)",
        "--scenario",
        "pass",
    ],
)

sh_test(
    name = "nextest_spike_expected_failure",
    test = ":nextest_adapter",
    args = [
        "cargo-fixture",
        "--manifest-path",
        "$(source fixture/Cargo.toml)",
        "--scenario",
        "fail",
    ],
)

sh_test(
    name = "nextest_spike_expected_failure_assert",
    test = "nextest_spike_expected_failure_assert.sh",
    resources = [
        ":nextest_adapter",
        "nextest_spike_expected_failure_assert.sh",
    ],
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
    resources = [
        ":nextest_buck_artifact_runner",
        "buck_artifact_scenario.sh",
    ],
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
    resources = [
        ":nextest_buck_artifact_runner",
        "buck_artifact_expected_failure_assert.sh",
    ],
)

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
    resources = [
        ":nextest_buck_artifact_runner",
        "buck_artifact_manifest_mutation.sh",
    ],
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
    resources = [
        ":nextest_buck_artifact_runner",
        "buck_artifact_invalid_manifest.sh",
    ],
)

sh_test(
    name = "validate_artifact_manifest",
    test = "validate_manifest_cases.sh",
    args = ["$(location :buck2_nextest_rust_test)"],
    resources = ["artifact-manifest.example.json", "tools/nextest_artifact.py"],
)

sh_test(
    name = "adapter_mode_validation",
    test = "adapter_mode_validation.sh",
    resources = ["adapter.sh"],
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
