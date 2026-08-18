NextestBuckToolchainInfo = provider(
    fields = ["cargo", "python", "cargo_nextest"],
)


def _nextest_system_tool_impl(ctx):
    executable = ctx.attrs.path
    return [
        DefaultInfo(),
        RunInfo(args = [executable]),
    ]


nextest_system_tool = rule(
    impl = _nextest_system_tool_impl,
    attrs = {
        "path": attrs.string(doc = "Configured local executable path."),
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
