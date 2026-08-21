load("@toolchains//:nextest.bzl", "NextestBuckToolchainInfo", "nextest_bundle_json")


def _nextest_buck_artifact_junit_impl(ctx):
    if ctx.attrs.timeout_seconds < 0 or ctx.attrs.timeout_seconds > 86400:
        fail("timeout_seconds must be between 0 and 86400")
    output = ctx.actions.declare_output("junit.xml")
    toolchain = ctx.attrs._nextest_toolchain[NextestBuckToolchainInfo]
    bundle_resources = toolchain.bundle_resources
    bundle_json = nextest_bundle_json(
        toolchain.bundle_version,
        toolchain.bundle_platform,
        bundle_resources,
        toolchain.bundle_environment,
    )
    resource_inputs = []
    for resource in bundle_resources:
        resource_inputs.append(resource["source"])

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
        "--action-metadata-parser", ctx.attrs.action_metadata_parser,
        "--cargo-argv", toolchain.cargo.args, "--end-argv",
        "--python-argv", toolchain.python.args, "--end-argv",
        "--cargo-nextest-argv", toolchain.cargo_nextest.args, "nextest", "--end-argv",
        "--bundle-json", bundle_json,
        "--bundle-resources",
        resource_inputs,
        "--end-bundle-resources",
        "--junit-report", output.as_output(),
        "--profile", ctx.attrs.profile,
        "--filter", ctx.attrs.filter,
        "--no-tests", ctx.attrs.no_tests,
        "--report-skipped", ctx.attrs.report_skipped,
        "--timeout-seconds", str(ctx.attrs.timeout_seconds),
    ])
    ctx.actions.run(
        command,
        category = "nextest_buck_artifact_junit",
        prefer_local = True,
        allow_cache_upload = False,
        metadata_env_var = "BUCK2_NEXTEST_ACTION_METADATA",
        metadata_path = "nextest-action-metadata.json",
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
        "action_metadata_parser": attrs.source(default = "//:nextest_buck_artifact_action_metadata"),
        "profile": attrs.string(default = "ci"),
        "filter": attrs.string(default = "test(=pass_case)"),
        "no_tests": attrs.enum(["auto", "pass", "warn", "fail"], default = "auto"),
        "report_skipped": attrs.enum(["default", "ignored"], default = "default"),
        "timeout_seconds": attrs.int(default = 0),
        "_adapter": attrs.exec_dep(default = "//:nextest_buck_artifact_runner", providers = [RunInfo]),
        "_nextest_toolchain": attrs.toolchain_dep(default = "toolchains//:nextest", providers = [NextestBuckToolchainInfo]),
    },
)
