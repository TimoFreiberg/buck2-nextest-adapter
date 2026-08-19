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
query = 'kind(run, //:nextest_buck_artifact_junit + //:nextest_buck_artifact_junit_custom)'
result = subprocess.run(
    [buck, "aquery", "--json", "--output-attribute", "^cmd$", query],
    cwd=project,
    check=True,
    capture_output=True,
    text=True,
)
actions = json.loads(result.stdout)
assert len(actions) == 2, actions
commands = list(actions.values())
profiles = []
for action in commands:
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
    profiles.append(command[command.index("--profile") + 1])
assert sorted(profiles) == ["ci", "custom-ci"], profiles
assert commands[0]["cmd"] != commands[1]["cmd"]
print("nextest action inspection: passed")
