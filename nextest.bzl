load("@toolchains//:nextest.bzl", "NextestBuckToolchainInfo")


def _nextest_buck_artifact_junit_impl(ctx):
    output = ctx.actions.declare_output("junit.xml")
    toolchain = ctx.attrs._nextest_toolchain[NextestBuckToolchainInfo]

    command = cmd_args([
        ctx.attrs._adapter[RunInfo],
        "buck-artifact",
        "--build-mode",
        "--artifact", ctx.attrs.artifact[DefaultInfo].default_outputs[0],
        "--manifest", ctx.attrs.manifest[DefaultInfo].default_outputs[0],
        "--validator", ctx.attrs.validator,
        "--cargo-baseline", ctx.attrs.cargo_baseline,
        "--binary-baseline", ctx.attrs.binary_baseline,
        "--tests-baseline", ctx.attrs.tests_baseline,
        "--runtime-resource", ctx.attrs.runtime_resource,
        "--source-denial", ctx.attrs.source_denial,
        "--cargo-command", toolchain.cargo.args,
        "--python-command", toolchain.python.args,
        "--cargo-nextest-command", toolchain.cargo_nextest.args, "nextest",
        "--junit-report", output.as_output(),
    ])
    ctx.actions.run(
        command,
        category = "nextest_buck_artifact_junit",
        local_only = True,
        allow_cache_upload = False,
    )
    return [DefaultInfo(default_output = output)]


nextest_buck_artifact_junit = rule(
    impl = _nextest_buck_artifact_junit_impl,
    attrs = {
        "artifact": attrs.dep(default = "//:buck2_nextest_rust_test"),
        "manifest": attrs.dep(default = "//:buck2_nextest_artifact_manifest"),
        "validator": attrs.source(default = "//:validator_file"),
        "cargo_baseline": attrs.source(default = "//:cargo_baseline"),
        "binary_baseline": attrs.source(default = "//:binary_baseline"),
        "tests_baseline": attrs.source(default = "//:tests_baseline"),
        "runtime_resource": attrs.source(default = "//:runtime_resource"),
        "source_denial": attrs.source(default = "//:source_denial"),
        "_adapter": attrs.exec_dep(default = "//:nextest_buck_artifact_runner", providers = [RunInfo]),
        "_nextest_toolchain": attrs.default_only(attrs.toolchain_dep(default = "toolchains//:nextest", providers = [NextestBuckToolchainInfo])),
    },
)
