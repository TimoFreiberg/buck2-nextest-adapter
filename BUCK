filegroup(
    name = "fixture/Cargo.toml",
    srcs = ["fixture/Cargo.toml"],
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

# The bundled prelude's $(location) expansion for a source-backed filegroup is
# directory-shaped here; $(source) keeps Cargo.toml beside its checked-in lockfile.
sh_test(
    name = "nextest_spike",
    test = ":nextest_adapter",
    args = [
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
        "--manifest-path",
        "$(source fixture/Cargo.toml)",
        "--scenario",
        "fail",
    ],
)
