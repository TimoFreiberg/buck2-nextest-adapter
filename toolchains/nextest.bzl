NextestBuckBundleResourceInfo = provider(
    fields = ["source", "path", "digest"],
)

NextestBuckToolchainInfo = provider(
    fields = [
        "cargo_nextest",
        "bundle_version",
        "bundle_resources",
        "bundle_environment",
        "bundle_platform",
    ],
)


def _is_safe_relative_path(value):
    if not value or value.startswith("/") or "\\" in value or "\x00" in value:
        return False
    parts = value.split("/")
    for part in parts:
        if not part or part == "." or part == "..":
            return False
    return True


def _is_safe_identity(value):
    if not value:
        return False
    for index in range(len(value)):
        char = value[index]
        if not ((char >= "a" and char <= "z") or (char >= "A" and char <= "Z") or (char >= "0" and char <= "9") or char in "._-:/"):
            return False
    return True


def _validate_digest(value):
    parts = value.split(":")
    if len(parts) != 3 or parts[0] != "sha256" or len(parts[1]) != 64 or not parts[2].isdigit():
        fail("bundle resource digest must be sha256:<hex>:<size>")
    for index in range(len(parts[1])):
        char = parts[1][index]
        if char not in "0123456789abcdefABCDEF":
            fail("bundle resource digest must contain hexadecimal bytes")


def _json_string(value):
    result = "\""
    for index in range(len(value)):
        char = value[index]
        if char == "\\":
            result += "\\\\"
        elif char == "\"":
            result += "\\\""
        elif char == "\b":
            result += "\\b"
        elif char == "\f":
            result += "\\f"
        elif char == "\n":
            result += "\\n"
        elif char == "\r":
            result += "\\r"
        elif char == "\t":
            result += "\\t"
        elif ord(char) < 32:
            result += "\\u00" + "0123456789abcdef"[ord(char) // 16] + "0123456789abcdef"[ord(char) % 16]
        else:
            result += char
    return result + "\""


def nextest_bundle_json(version, platform, resources, environment):
    resource_values = []
    for resource in resources:
        resource_values.append(
            "{" +
            "\"digest\":" + _json_string(resource["digest"]) + "," +
            "\"path\":" + _json_string(resource["path"]) + "," +
            "\"source\":" + _json_string(resource["source"].short_path) +
            "}"
        )
    environment_values = []
    for item in environment:
        environment_values.append(
            "{" +
            "\"kind\":" + _json_string(item["kind"]) + "," +
            "\"name\":" + _json_string(item["name"]) + "," +
            "\"value\":" + _json_string(item["value"]) +
            "}"
        )
    return (
        "{\"bundle_environment\":[" + ",".join(environment_values) +
        "],\"bundle_platform\":" + _json_string(platform) +
        ",\"bundle_resources\":[" + ",".join(resource_values) +
        "],\"bundle_version\":" + str(version) + "}"
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


def _nextest_bundle_resource_impl(ctx):
    outputs = ctx.attrs.resource[DefaultInfo].default_outputs
    if len(outputs) != 1:
        fail("nextest bundle resource must provide exactly one default output")
    path = ctx.attrs.path
    if not _is_safe_relative_path(path):
        fail("bundle resource path must be a normalized relative POSIX path")
    _validate_digest(ctx.attrs.digest)
    return [
        DefaultInfo(default_output = outputs[0]),
        NextestBuckBundleResourceInfo(source = outputs[0], path = path, digest = ctx.attrs.digest),
    ]


nextest_bundle_resource = rule(
    impl = _nextest_bundle_resource_impl,
    attrs = {
        "resource": attrs.exec_dep(providers = [DefaultInfo]),
        "path": attrs.string(),
        "digest": attrs.string(),
    },
)


def _nextest_toolchain_impl(ctx):
    resources = []
    if len(ctx.attrs.bundle_resources) == 0:
        fail("nextest toolchain requires at least one bundle resource")
    seen_sources = {}
    seen_paths = {}
    for target in ctx.attrs.bundle_resources:
        resource = target[NextestBuckBundleResourceInfo]
        source = resource.source.short_path
        if source in seen_sources:
            fail("duplicate bundle resource source: {}".format(source))
        if resource.path in seen_paths:
            fail("duplicate bundle resource path: {}".format(resource.path))
        if not _is_safe_relative_path(source) or not _is_safe_relative_path(resource.path):
            fail("bundle resource paths must be normalized relative POSIX paths")
        _validate_digest(resource.digest)
        seen_sources[source] = True
        seen_paths[resource.path] = True
        resources.append({"source": resource.source, "path": resource.path, "digest": resource.digest})
    platform = ctx.attrs.bundle_platform
    if not _is_safe_identity(platform):
        fail("bundle_platform must be a non-empty safe execution identity")
    environment = []
    seen_names = {}
    for item in ctx.attrs.bundle_environment:
        if len(item) != 3:
            fail("bundle_environment records must be [name, kind, value]")
        name, kind, value = item
        if not name or name in seen_names or "=" in name or "\x00" in name:
            fail("bundle environment names must be unique shell names")
        if not (name[0].isalpha() or name[0] == "_"):
            fail("bundle environment names must be unique shell names")
        for index in range(len(name)):
            char = name[index]
            if not ((char >= "a" and char <= "z") or (char >= "A" and char <= "Z") or (char >= "0" and char <= "9") or char == "_"):
                fail("bundle environment names must be unique ASCII shell names")
        if kind not in ["literal", "relative_path"] or "\x00" in value:
            fail("bundle environment records have an invalid kind or value")
        if kind == "relative_path" and not _is_safe_relative_path(value):
            fail("relative_path environment values must be normalized relative POSIX paths")
        seen_names[name] = True
        environment.append({"name": name, "kind": kind, "value": value})
    return [
        DefaultInfo(),
        NextestBuckToolchainInfo(
            cargo_nextest = ctx.attrs.cargo_nextest[RunInfo],
            bundle_version = 1,
            bundle_resources = resources,
            bundle_environment = environment,
            bundle_platform = platform,
        ),
    ]


nextest_toolchain = rule(
    impl = _nextest_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {
        "cargo_nextest": attrs.exec_dep(providers = [RunInfo]),
        "bundle_resources": attrs.list(attrs.exec_dep(providers = [NextestBuckBundleResourceInfo])),
        "bundle_environment": attrs.list(attrs.list(attrs.string()), default = []),
        "bundle_platform": attrs.string(default = "local-fixture-v1"),
    },
)
