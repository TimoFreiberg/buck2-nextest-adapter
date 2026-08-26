load("@prelude//test:inject_test_run_info.bzl", "inject_test_run_info")


def _nextest_v2_executor_fixture_impl(ctx):
    command = cmd_args(ctx.attrs.executable[RunInfo].args)
    return inject_test_run_info(
        ctx,
        ExternalRunnerTestInfo(
            type = ctx.attrs.test_type,
            command = [command],
            env = {
                "BUCK2_EXECUTOR_FIXTURE_MODE": ctx.attrs.mode,
                "BUCK2_EXECUTOR_FIXTURE_NONCE": ctx.attrs.nonce,
            },
            labels = ["private-executor-fixture"],
            contacts = [],
            run_from_project_root = True,
            use_project_relative_paths = True,
            supports_test_execution_caching = False,
        ),
    ) + [DefaultInfo()]


nextest_v2_executor_fixture = rule(
    impl = _nextest_v2_executor_fixture_impl,
    attrs = {
        "executable": attrs.exec_dep(providers = [DefaultInfo, RunInfo]),
        "mode": attrs.string(),
        "test_type": attrs.string(default = "nextest"),
        "nonce": attrs.string(default = "fixture"),
        "labels": attrs.list(attrs.string(), default = []),
        "contacts": attrs.list(attrs.string(), default = []),
        "_inject_test_env": attrs.default_only(attrs.dep(default = "prelude//test/tools:inject_test_env")),
    },
)
