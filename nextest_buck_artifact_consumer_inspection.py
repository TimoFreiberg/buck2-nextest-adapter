#!/usr/bin/env python3
import json
import subprocess
import sys

buck, project = sys.argv[1:]
target = "//:nextest_buck_artifact_junit_expected_failure_consumer"
producer = "root//:nextest_buck_artifact_junit_expected_failure"
expected_output = "nextest-buck-artifact-junit-expected-failure-copy.txt"

def run(*args):
    return subprocess.run([buck, *args], cwd=project, check=True, capture_output=True, text=True)

targets = json.loads(run("targets", "--json", target).stdout)
assert len(targets) == 1, targets
entry = targets[0]
assert entry["name"] == target.removeprefix("//:"), entry
assert entry["out"] == expected_output, entry
assert entry["srcs"] == [producer], entry
assert producer in entry["buck.deps"], entry
assert entry["cmd"] == f"cp $(location {producer}) $OUT", entry

actions = json.loads(run("aquery", "--json", "--output-attribute", "^cmd$", f"kind(run, {target})").stdout)
assert len(actions) == 1, actions
owner = next(iter(actions))
assert owner.startswith(f"(target: `root{target} "), owner
assert actions[owner]["cmd"].startswith("[/usr/bin/env, bash, -e, "), actions
print("nextest consumer inspection: passed")
