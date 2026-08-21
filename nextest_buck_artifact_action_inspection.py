#!/usr/bin/env python3
import json
import shlex
import subprocess
import sys
from pathlib import Path

buck, project = sys.argv[1:]
toolchain = Path(project, "toolchains", "BUCK").read_text()
configured = {
    "cargo": "root//:nextest-cargo-executable",
    "python": "root//:nextest-python-executable",
    "cargo_nextest_v1": "root//:nextest-cargo-nextest-v1-executable",
    "cargo_nextest_v2": "root//:nextest-cargo-nextest-v2-executable",
}

assert 'metadata_env_var = "BUCK2_NEXTEST_ACTION_METADATA"' in Path(project, "nextest.bzl").read_text()
assert 'metadata_path = "nextest-action-metadata.json"' in Path(project, "nextest.bzl").read_text()
assert "action_metadata_parser" in Path(project, "nextest.bzl").read_text()
assert "attrs.exec_dep" in Path(project, "toolchains", "nextest.bzl").read_text()
toolchain_impl = Path(project, "toolchains", "nextest.bzl").read_text()
assert "providers = [DefaultInfo, RunInfo]" in toolchain_impl
assert "default_outputs" in toolchain_impl
assert "RunInfo(args = cmd_args" in toolchain_impl
query = 'kind(run, //:nextest_buck_artifact_junit + //:nextest_buck_artifact_junit_custom + //:nextest_buck_artifact_junit_tool_v1 + //:nextest_buck_artifact_junit_tool_v2 + //:nextest_buck_artifact_junit_expected_failure)'
result = subprocess.run(
    [buck, "aquery", "--json", "--output-attribute", "^cmd$", query],
    cwd=project,
    check=True,
    capture_output=True,
    text=True,
)
actions = json.loads(result.stdout)
assert len(actions) == 5, actions
commands = list(actions.values())
profiles = []
def action_target(action_key):
    prefix = "(target: `"
    suffix = " ("
    assert action_key.startswith(prefix) and suffix in action_key, action_key
    target = action_key[len(prefix):].split(suffix, 1)[0]
    assert target.startswith("root//:"), action_key
    return target

targets = [action_target(target) for target in actions]
expected_targets = {
    "root//:nextest_buck_artifact_junit": ("ci", "test(=pass_case)"),
    "root//:nextest_buck_artifact_junit_custom": ("custom-ci", "test(=pass_case)"),
    "root//:nextest_buck_artifact_junit_expected_failure": ("ci", "test(=fail_case)"),
    "root//:nextest_buck_artifact_junit_tool_v1": ("ci", "test(=pass_case)"),
    "root//:nextest_buck_artifact_junit_tool_v2": ("ci", "test(=pass_case)"),
}
assert set(targets) == set(expected_targets), targets
for target_key, action in actions.items():
    target = action_target(target_key)
    command = [value.rstrip(",") for value in shlex.split(action["cmd"].strip("[]"))]
    for pair in (
        "--profile",
        "--filter",
        "--no-tests",
        "--report-skipped",
        "--timeout-seconds",
        "--cargo-argv",
        "--python-argv",
        "--cargo-nextest-argv",
        "--bundle-json",
        "--bundle-resources",
        "--action-metadata-parser",
    ):
        assert pair in command, (pair, command)
    cargo_nextest_index = command.index("--cargo-nextest-argv")
    assert cargo_nextest_index + 2 < len(command), command
    if target.endswith("tool_v2"):
        assert "nextest-cargo-nextest-v2" in command[cargo_nextest_index + 1], command
    else:
        assert "nextest-cargo-nextest-v1" in command[cargo_nextest_index + 1], command
    assert command[cargo_nextest_index + 2] == "nextest", command
    assert command[cargo_nextest_index + 3] == "--end-argv", command
    bundle_index = command.index("--bundle-json")
    bundle_text = action["cmd"].split("--bundle-json, ", 1)[1].split(", --bundle-resources", 1)[0]
    bundle = json.loads(bundle_text.replace('\\"', '"'))
    assert bundle["bundle_version"] == 1, bundle
    assert bundle["bundle_platform"].startswith("local-fixture-v"), bundle
    assert bundle["bundle_resources"] == [{
        "digest": "sha256:5fbd981ca9311519215669ba854c8110d4f58bd015d49827e979280e0500bfe1:34",
        "path": "runtime/fixture-resource.txt",
        "source": "nextest-bundle-runtime-resource.txt",
    }], bundle
    assert command[bundle_index + 2] == "--bundle-resources", command
    assert "nextest-bundle-runtime-resource" in command[bundle_index + 3], command
    assert command[bundle_index + 4] == "--end-bundle-resources", command
    parser_index = command.index("--action-metadata-parser")
    assert parser_index + 1 < len(command), command
    assert "nextest_buck_artifact_action_metadata" in command[parser_index + 1], command
    profile = command[command.index("--profile") + 1]
    filter_value = command[command.index("--filter") + 1]
    assert (profile, filter_value) == expected_targets[target], (target, command)
    profiles.append(profile)
assert sorted(profiles) == ["ci", "ci", "ci", "ci", "custom-ci"], profiles
assert len({action["cmd"] for action in commands}) == 5
print("nextest action inspection: passed")
