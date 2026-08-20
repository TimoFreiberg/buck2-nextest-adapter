NextestBuckToolchainInfo = provider(
    fields = ["cargo", "python", "cargo_nextest"],
)


def _nextest_system_tool_impl(ctx):
    default_outputs = ctx.attrs.executable[DefaultInfo].default_outputs
    if len(default_outputs) != 1:
        fail("nextest_system_tool executable must provide exactly one default output")
    return [
        DefaultInfo(default_output = default_outputs[0]),
        RunInfo(args = cmd_args(ctx.attrs.executable[RunInfo].args)),
    ]


nextest_system_tool = rule(
    impl = _nextest_system_tool_impl,
    attrs = {
        "executable": attrs.exec_dep(
            providers = [DefaultInfo, RunInfo],
            doc = "An executable target providing exactly one default output and RunInfo.",
        ),
    },
)


def _nextest_toolchain_impl(ctx):
    return [
        DefaultInfo(),
        NextestBuckToolchainInfo(
            cargo = ctx.attrs.cargo[RunInfo],
            python = ctx.attrs.python[RunInfo],
            cargo_nextest = ctx.attrs.cargo_nextest[RunInfo],
        ),
    ]


nextest_toolchain = rule(
    impl = _nextest_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {
        "cargo": attrs.exec_dep(providers = [RunInfo]),
        "python": attrs.exec_dep(providers = [RunInfo]),
        "cargo_nextest": attrs.exec_dep(providers = [RunInfo]),
    },
)
