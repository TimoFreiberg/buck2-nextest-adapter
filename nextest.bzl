load("@prelude//test:inject_test_run_info.bzl", "inject_test_run_info")
load("@toolchains//:nextest.bzl", "NextestBuckToolchainInfo", "nextest_bundle_json")

def _is_canonical_owner_label(value):
    if not value.startswith("//") or " " in value or "\t" in value or "\n" in value:
        return False
    body = value[2:]
    if body.startswith(":"):
        return len(body) > 1
    parts = body.split(":")
    if len(parts) != 2 or not parts[0] or not parts[1]:
        return False
    for component in parts[0].split("/"):
        if not component:
            return False
    return True


NextestBuckTestBinaryInfo = provider(
    fields = [
        "package_identity",
        "owner_label",
        "binary_identity",
        "display_name",
        "target_kind",
        "executable",
        "runtime",
        "generated_outputs",
        "cwd",
        "platform",
        "environment",
    ],
)


def _nextest_buck_test_binary_impl(ctx):
    if not _is_canonical_owner_label(ctx.attrs.owner_label):
        fail("nextest_buck_test_binary owner_label must be a canonical Buck label")
    outputs = ctx.attrs.executable[DefaultInfo].default_outputs
    if len(outputs) != 1:
        fail("nextest_buck_test_binary executable must provide exactly one default output")
    if len(ctx.attrs.runtime) != len(ctx.attrs.runtime_destinations):
        fail("runtime and runtime_destinations must have the same length")
    runtime = []
    for dependency, destination in zip(ctx.attrs.runtime, ctx.attrs.runtime_destinations):
        dependency_outputs = dependency[DefaultInfo].default_outputs
        if len(dependency_outputs) != 1:
            fail("each nextest_buck_test_binary runtime dependency must provide exactly one output")
        runtime.append({"source": dependency_outputs[0], "destination": destination, "kind": "regular_file"})
    executable = outputs[0]
    if executable.is_source:
        fail("nextest_buck_test_binary executable must be a Buck-produced regular file")
    return [
        DefaultInfo(default_output = executable),
        RunInfo(args = ctx.attrs.executable[RunInfo].args),
        NextestBuckTestBinaryInfo(
            package_identity = ctx.attrs.package_identity,
            owner_label = ctx.attrs.owner_label,
            binary_identity = ctx.attrs.binary_identity,
            display_name = ctx.attrs.display_name,
            target_kind = ctx.attrs.target_kind,
            executable = {"source": executable, "destination": ctx.attrs.executable_destination, "kind": "regular_file"},
            runtime = runtime,
            generated_outputs = [],
            cwd = ctx.attrs.cwd,
            platform = ctx.attrs.platform,
            environment = ctx.attrs.environment,
        ),
    ]


nextest_buck_test_binary = rule(
    impl = _nextest_buck_test_binary_impl,
    attrs = {
        "executable": attrs.exec_dep(providers = [DefaultInfo, RunInfo]),
        "runtime": attrs.list(attrs.exec_dep(providers = [DefaultInfo]), default = []),
        "runtime_destinations": attrs.list(attrs.string(), default = []),
        "package_identity": attrs.string(),
        "owner_label": attrs.string(),
        "binary_identity": attrs.string(),
        "display_name": attrs.string(),
        "target_kind": attrs.string(default = "test"),
        "executable_destination": attrs.string(),
        "cwd": attrs.string(),
        "platform": attrs.string(),
        "environment": attrs.dict(key = attrs.string(), value = attrs.string(), default = {}),
    },
)


def _nextest_buck_test_impl(ctx):
    records = []
    for dependency in ctx.attrs.records:
        if NextestBuckTestBinaryInfo not in dependency:
            fail("nextest_buck_test records must provide NextestBuckTestBinaryInfo")
        record = dependency[NextestBuckTestBinaryInfo]
        records.append(record)
    if not records:
        fail("nextest_buck_test requires at least one binary record")
    manifest_records = []
    executable_sources = {}
    for record in records:
        executable = record.executable["source"]
        executable_source = executable.short_path
        if executable_source in executable_sources:
            fail("nextest_buck_test records share one executable association: {} and {}".format(executable_sources[executable_source], record.binary_identity))
        executable_sources[executable_source] = record.binary_identity
        manifest_runtime = []
        for runtime in record.runtime:
            manifest_runtime.append({
                "source": runtime["source"].short_path,
                "destination": runtime["destination"],
                "kind": runtime["kind"],
            })
        manifest_records.append({
            "package_identity": record.package_identity,
            "owner_label": record.owner_label,
            "binary_identity": record.binary_identity,
            "display_name": record.display_name,
            "target_kind": record.target_kind,
            "executable": {
                "source": executable_source,
                "destination": record.executable["destination"],
                "kind": record.executable["kind"],
            },
            "runtime": manifest_runtime,
            "generated_outputs": record.generated_outputs,
            "cwd": record.cwd,
            "platform": record.platform,
            "environment": record.environment,
        })
    manifest = ctx.actions.write_json(
        "nextest-buck-test-manifest.json",
        {"schema_version": 2, "records": manifest_records},
    )
    declared_inputs = []
    for record in records:
        declared_inputs.extend(["--declared-input", record.executable["source"]])
        for runtime in record.runtime:
            declared_inputs.extend(["--declared-input", runtime["source"]])
    command = cmd_args(
        [
            ctx.attrs._contract_runner[RunInfo],
            "--manifest", manifest,
            "--record-count", str(len(records)),
        ] + declared_inputs,
        hidden = [
            record.executable["source"]
            for record in records
        ] + [
            runtime["source"]
            for record in records
            for runtime in record.runtime
        ],
    )
    return inject_test_run_info(
        ctx,
        ExternalRunnerTestInfo(
            type = "nextest",
            command = [command],
            env = ctx.attrs.env,
            labels = ctx.attrs.labels,
            contacts = ctx.attrs.contacts,
            run_from_project_root = True,
            use_project_relative_paths = True,
            supports_test_execution_caching = False,
        ),
    ) + [DefaultInfo()]


nextest_buck_test = rule(
    impl = _nextest_buck_test_impl,
    attrs = {
        "records": attrs.list(attrs.dep(providers = [NextestBuckTestBinaryInfo])),
        "_contract_runner": attrs.exec_dep(default = "//:nextest_buck_test_contract_runner", providers = [RunInfo]),
        "env": attrs.dict(key = attrs.string(), value = attrs.arg(), default = {}),
        "labels": attrs.list(attrs.string(), default = []),
        "contacts": attrs.list(attrs.string(), default = []),
        "_inject_test_env": attrs.default_only(attrs.dep(default = "prelude//test/tools:inject_test_env")),
    },
)


def _nextest_executable_impl(ctx):
    output = ctx.actions.declare_output(ctx.attrs.out)
    ctx.actions.run(cmd_args([
        "sh",
        "-c",
        'cp "$1" "$2" && chmod +x "$2"',
        "nextest-executable-copy",
        ctx.attrs.source,
        output.as_output(),
    ]), category = "nextest_executable_copy")
    return [DefaultInfo(default_output = output), RunInfo(args = cmd_args(output))]


nextest_executable = rule(
    impl = _nextest_executable_impl,
    attrs = {
        "source": attrs.source(),
        "out": attrs.string(),
    },
)


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
        "--cargo-baseline", ctx.attrs.cargo_baseline,
        "--binary-baseline", ctx.attrs.binary_baseline,
        "--tests-baseline", ctx.attrs.tests_baseline,
        "--cargo-nextest-argv", toolchain.cargo_nextest.args, "--end-argv",
        "--runtime-resource", ctx.attrs.runtime_resource,
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
        "cargo_baseline": attrs.source(default = "//:cargo_baseline"),
        "binary_baseline": attrs.source(default = "//:binary_baseline"),
        "tests_baseline": attrs.source(default = "//:tests_baseline"),
        "runtime_resource": attrs.source(default = "//:runtime_resource"),
        "profile": attrs.string(default = "ci"),
        "filter": attrs.string(default = "test(=pass_case)"),
        "no_tests": attrs.enum(["auto", "pass", "warn", "fail"], default = "auto"),
        "report_skipped": attrs.enum(["default", "ignored"], default = "default"),
        "timeout_seconds": attrs.int(default = 0),
        "_adapter": attrs.exec_dep(default = "//:nextest_buck_artifact_runner", providers = [RunInfo]),
        "_nextest_toolchain": attrs.toolchain_dep(default = "toolchains//:nextest", providers = [NextestBuckToolchainInfo]),
    },
)
