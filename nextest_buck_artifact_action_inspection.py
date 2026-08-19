#!/usr/bin/env python3
import json
import shlex
import subprocess
import sys
from pathlib import Path

buck, project = sys.argv[1:]
toolchain = Path(project, "toolchains", "BUCK").read_text()
configured = {}
for name in ("cargo", "python", "cargo_nextest"):
    marker = f'name = "nextest-{name.replace("_", "-")}"'
    section = toolchain.split(marker, 1)[1].split(")", 1)[0]
    configured[name] = next(line.split('"', 2)[1] for line in section.splitlines() if "path =" in line)
query = 'kind(run, //:nextest_buck_artifact_junit + //:nextest_buck_artifact_junit_custom + //:nextest_buck_artifact_junit_expected_failure)'
result = subprocess.run(
    [buck, "aquery", "--json", "--output-attribute", "^cmd$", query],
    cwd=project,
    check=True,
    capture_output=True,
    text=True,
)
actions = json.loads(result.stdout)
assert len(actions) == 3, actions
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
        "--cargo-command",
        "--python-command",
        "--cargo-nextest-command",
    ):
        assert pair in command, (pair, command)
    assert command[command.index("--cargo-command") + 1] == configured["cargo"], command
    assert command[command.index("--python-command") + 1] == configured["python"], command
    cargo_nextest_index = command.index("--cargo-nextest-command")
    assert command[cargo_nextest_index + 1] == configured["cargo_nextest"], command
    assert command[cargo_nextest_index + 2] == "nextest", command
    profile = command[command.index("--profile") + 1]
    filter_value = command[command.index("--filter") + 1]
    assert (profile, filter_value) == expected_targets[target], (target, command)
    profiles.append(profile)
assert sorted(profiles) == ["ci", "ci", "custom-ci"], profiles
assert len({action["cmd"] for action in commands}) == 3
print("nextest action inspection: passed")
