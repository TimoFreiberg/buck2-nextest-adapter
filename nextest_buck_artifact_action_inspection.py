#!/usr/bin/env python3
import json
import shlex
import subprocess
import sys

buck, project = sys.argv[1:]
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
    ):
        assert pair in command, (pair, command)
    profiles.append(command[command.index("--profile") + 1])
assert sorted(profiles) == ["ci", "custom-ci"], profiles
assert commands[0]["cmd"] != commands[1]["cmd"]
print("nextest action inspection: passed")
