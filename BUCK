filegroup(
    name = "fixture/Cargo.toml",
    srcs = ["fixture/Cargo.toml"],
)

filegroup(
    name = "tools",
    srcs = ["tools/nextest_artifact.py"],
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
    cmd = "python3 $(source tools/nextest_artifact.py) emit-manifest --artifact $(location :buck2_nextest_rust_test) --output $OUT",
    srcs = ["tools/nextest_artifact.py", ":buck2_nextest_rust_test"],
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

sh_binary(
    name = "nextest_buck_artifact_runner",
    main = "adapter.sh",
    append_script_extension = False,
    resources = [
        ":buck2_nextest_rust_test",
        ":buck2_nextest_artifact_manifest",
        "tools/nextest_artifact.py",
        "tools/cargo_source_denial.sh",
        ":baseline",
    ],
)

sh_test(
    name = "nextest_buck_artifact",
    test = ":nextest_buck_artifact_runner",
    args = [
        "buck-artifact",
        "--artifact",
        "$(location :buck2_nextest_rust_test)",
        "--manifest",
        "$(location :buck2_nextest_artifact_manifest)",
        "--validator",
        "$(source tools/nextest_artifact.py)",
        "--cargo-baseline",
        "$(source baseline/normalized/cargo-metadata.json)",
        "--binary-baseline",
        "$(source baseline/normalized/binaries.json)",
        "--tests-baseline",
        "$(source baseline/normalized/tests.json)",
        "--scenario",
        "pass",
    ],
)

sh_test(
    name = "nextest_buck_artifact_expected_failure",
    test = ":nextest_buck_artifact_runner",
    args = [
        "buck-artifact",
        "--artifact",
        "$(location :buck2_nextest_rust_test)",
        "--manifest",
        "$(location :buck2_nextest_artifact_manifest)",
        "--validator",
        "$(source tools/nextest_artifact.py)",
        "--cargo-baseline",
        "$(source baseline/normalized/cargo-metadata.json)",
        "--binary-baseline",
        "$(source baseline/normalized/binaries.json)",
        "--tests-baseline",
        "$(source baseline/normalized/tests.json)",
        "--scenario",
        "fail",
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
    resources = ["README.md", "docs/nextest-buck2-roadmap.md"],
)

sh_test(
    name = "adapter_signal_cleanup",
    test = "adapter_signal_cleanup.sh",
)
