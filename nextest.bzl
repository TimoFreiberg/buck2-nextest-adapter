load("@prelude//test:inject_test_run_info.bzl", "inject_test_run_info")
load("@toolchains//:nextest.bzl", "NextestBuckToolchainInfo", "nextest_bundle_json")
load("@prelude//dist:dist_info.bzl", "DistInfo")

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


def _is_valid_suite_environment(environment):
    reserved = ["PATH", "HOME", "TMPDIR", "CARGO_HOME", "CARGO_TARGET_DIR", "CARGO_MANIFEST_DIR", "CARGO_NET_OFFLINE", "CARGO_NET_GIT_FETCH_WITH_CLI"]
    for name, value in environment.items():
        if not name or not name[0].isalpha() and name[0] != "_":
            return False
        for index in range(len(name)):
            char = name[index]
            if not (char.isalnum() or char == "_"):
                return False
        if name.startswith("BUCK2_NEXTEST_") or name in reserved or "\x00" in str(value):
            return False
    return True


def _is_normalized_relative_path(value):
    if not value or value.startswith("/") or "\\" in value or "\x00" in value:
        return False
    for component in value.split("/"):
        if not component or component == "." or component == "..":
            return False
    return True


def _is_toml_safe_path(value):
    if not _is_normalized_relative_path(value) or '"' in value:
        return False
    for control in ["\x00", "\x01", "\x02", "\x03", "\x04", "\x05", "\x06", "\x07", "\x08", "\x09", "\x0a", "\x0b", "\x0c", "\x0d", "\x0e", "\x0f", "\x10", "\x11", "\x12", "\x13", "\x14", "\x15", "\x16", "\x17", "\x18", "\x19", "\x1a", "\x1b", "\x1c", "\x1d", "\x1e", "\x1f", "\x7f"]:
        if control in value:
            return False
    return True


def _paths_overlap(left, right):
    return left == right or left.startswith(right + "/") or right.startswith(left + "/")


NextestBuckTestBinaryInfo = provider(
    fields = [
        "package_identity",
        "owner_label",
        "binary_identity",
        "display_name",
        "target_kind",
        "executable",
        "runtime_files",
        "cwd",
        "platform",
    ],
)


def _nextest_buck_test_binary_impl(ctx):
    if not _is_canonical_owner_label(ctx.attrs.owner_label):
        fail("nextest_buck_test_binary owner_label must be a canonical Buck label")
    outputs = ctx.attrs.executable[DefaultInfo].default_outputs
    if len(outputs) != 1:
        fail("nextest_buck_test_binary executable must provide exactly one default output")
    executable = outputs[0]
    runtime_files = ctx.attrs.executable[DistInfo].nondebug_runtime_files
    if executable.is_source:
        fail("nextest_buck_test_binary executable must be a Buck-produced regular file")
    return [
        DefaultInfo(default_output = executable),
        RunInfo(args = cmd_args(executable, hidden = runtime_files)),
        NextestBuckTestBinaryInfo(
            package_identity = ctx.attrs.package_identity,
            owner_label = ctx.attrs.owner_label,
            binary_identity = ctx.attrs.binary_identity,
            display_name = ctx.attrs.display_name,
            target_kind = ctx.attrs.target_kind,
            executable = {"source": executable, "kind": "regular_file"},
            runtime_files = runtime_files,
            cwd = ctx.attrs.cwd,
            platform = ctx.attrs.platform,
        ),
    ]


nextest_buck_test_binary = rule(
    impl = _nextest_buck_test_binary_impl,
    attrs = {
        "executable": attrs.exec_dep(providers = [DefaultInfo, RunInfo, DistInfo]),
        "package_identity": attrs.string(),
        "owner_label": attrs.string(),
        "binary_identity": attrs.string(),
        "display_name": attrs.string(),
        "target_kind": attrs.string(default = "test"),
        "cwd": attrs.string(),
        "platform": attrs.string(),
    },
)


def _nextest_buck_test_impl(ctx):
    if not _is_valid_suite_environment(ctx.attrs.env):
        fail("nextest_buck_test env contains an invalid or adapter-owned variable")
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
    package_cwds = {}
    cwd_packages = {}
    for record in records:
        executable = record.executable["source"]
        executable_source = executable.short_path
        if executable_source in executable_sources:
            fail("nextest_buck_test records share one executable association: {} and {}".format(executable_sources[executable_source], record.binary_identity))
        executable_sources[executable_source] = record.binary_identity
        if not _is_toml_safe_path(record.cwd):
            fail("nextest_buck_test cwd must be a TOML-safe normalized relative POSIX path")
        if record.package_identity in package_cwds and package_cwds[record.package_identity] != record.cwd:
            fail("nextest_buck_test records for one package_identity must share one cwd")
        if record.package_identity not in package_cwds:
            for package, cwd in package_cwds.items():
                if package != record.package_identity and _paths_overlap(cwd, record.cwd):
                    fail("nextest_buck_test package cwds must not overlap")
        package_cwds[record.package_identity] = record.cwd
        if record.cwd in cwd_packages and cwd_packages[record.cwd] != record.package_identity:
            fail("nextest_buck_test cwd must map to one package_identity")
        cwd_packages[record.cwd] = record.package_identity
        manifest_records.append({
            "package_identity": record.package_identity,
            "owner_label": record.owner_label,
            "binary_identity": record.binary_identity,
            "display_name": record.display_name,
            "target_kind": record.target_kind,
            "executable": {
                "source": executable_source,
                "kind": record.executable["kind"],
            },
            "cwd": record.cwd,
            "platform": record.platform,
        })
    manifest = ctx.actions.write_json(
        "nextest-buck-test-manifest.json",
        {"schema_version": 2, "records": manifest_records},
    )
    declared_inputs = []
    for record in records:
        declared_inputs.extend(["--declared-input", record.executable["source"]])
    toolchain = ctx.attrs._nextest_toolchain[NextestBuckToolchainInfo]
    bundle_resources = toolchain.bundle_resources
    bundle_json = nextest_bundle_json(
        toolchain.bundle_version,
        toolchain.bundle_platform,
        bundle_resources,
        toolchain.bundle_environment,
    )
    resource_inputs = [resource["source"] for resource in bundle_resources]
    configured_environment = dict(ctx.attrs.env)
    observation_dir = read_root_config("nextest_test", "observation_dir", "")
    nonce = read_root_config("nextest_test", "nonce", "")
    if observation_dir and not nonce:
        fail("nextest_test.nonce is required with nextest_test.observation_dir")
    if nonce and not observation_dir:
        fail("nextest_test.observation_dir is required with nextest_test.nonce")
    for name, value in [
        ("NEXTEST_TEST_OBSERVATION_DIR", observation_dir),
        ("NEXTEST_TEST_NONCE", nonce),
    ]:
        if value:
            if name in configured_environment:
                fail("nextest_test config cannot override a user suite environment variable")
            configured_environment[name] = value
    suite_environment = []
    for name, value in configured_environment.items():
        suite_environment.extend(["--suite-env", name, value])
    command = cmd_args(
        [
            ctx.attrs._runner[RunInfo],
            "--manifest", manifest,
            "--record-count", str(len(records)),
            "--cargo-nextest-argv", toolchain.cargo_nextest.args, "--end-argv",
            "--bundle-json", bundle_json,
            "--bundle-resources", resource_inputs, "--end-bundle-resources",
            "--profile", ctx.attrs.profile,
            "--filter", ctx.attrs.filter,
            "--no-tests", ctx.attrs.no_tests,
            "--report-skipped", ctx.attrs.report_skipped,
            "--timeout-seconds", str(ctx.attrs.timeout_seconds),
        ] + suite_environment + declared_inputs,
        hidden = [
            record.executable["source"]
            for record in records
        ] + [
            record.runtime_files
            for record in records
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
        "_runner": attrs.exec_dep(default = "//:nextest_buck_test_runner", providers = [RunInfo]),
        "_nextest_toolchain": attrs.toolchain_dep(default = "toolchains//:nextest-real", providers = [NextestBuckToolchainInfo]),
        "profile": attrs.string(default = "ci"),
        "filter": attrs.string(default = "test(=pass_case)"),
        "no_tests": attrs.enum(["auto", "pass", "warn", "fail"], default = "auto"),
        "report_skipped": attrs.enum(["default", "ignored"], default = "default"),
        "timeout_seconds": attrs.int(default = 0),
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
