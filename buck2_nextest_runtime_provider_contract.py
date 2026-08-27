#!/usr/bin/env python3
"""Check the production DistInfo runtime-provider and action contract.

This is a repository-level check because the pinned Buck does not expose an
ExternalRunnerTestInfo command as an aquery ``run`` action.  The executable's
provider materialization is therefore checked with ``all_actions`` while the
production nextest command is checked in a fresh what-ran event log.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

VALID_WRAPPER = "//:nextest_buck_test_runtime_closure_positive"
VALID_EXECUTABLE = "//:buck2_nextest_runtime_resource_positive_executable"
INVALID_WRAPPER = "//:nextest_buck_test_binary_runtime_invalid"
MISSING_DISTINFO = "Attribute requires a dep that provides `DistInfo`, but it was not found on"


def run(command: list[str], project: Path, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=project, text=True, capture_output=True, check=check)


def fail(message: str, *output: str) -> "NoReturn":
    print(f"runtime provider contract: {message}", file=sys.stderr)
    for value in output:
        if value:
            print(value, file=sys.stderr)
    raise SystemExit(1)


def action_target(key: str) -> str:
    prefix = "(target: `"
    marker = " ("
    if not key.startswith(prefix) or marker not in key:
        fail(f"unrecognized aquery action key: {key}")
    return key[len(prefix):].split(marker, 1)[0]


def load_aquery(buck: str, project: Path, target: str) -> dict[str, dict[str, object]]:
    result = run([buck, "aquery", "--json", "-A", f"all_actions({target})"], project)
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        fail(f"aquery did not return JSON: {exc}", result.stdout, result.stderr)
    if not isinstance(value, dict) or not value:
        fail(f"aquery returned no actions for {target}", result.stdout)
    return value


def check_resource_materialization(buck: str, project: Path) -> None:
    actions = load_aquery(buck, project, VALID_EXECUTABLE)
    target_actions = [
        action for key, action in actions.items() if action_target(key) == f"root{VALID_EXECUTABLE}"
    ]
    if not target_actions:
        fail(f"aquery contained no actions for {VALID_EXECUTABLE}")

    resource_json = [
        action
        for action in target_actions
        if action.get("kind") == "write"
        and action.get("category") == "write_json"
        and action.get("identifier") == "buck2_nextest_runtime_resource_positive_executable.resources.json"
    ]
    if len(resource_json) != 1:
        fail("generated resource database action was not unique")
    contents = resource_json[0].get("contents", "")
    if "nextest-generated-rust-runtime-resource.txt" not in contents:
        fail("resource database action did not declare the generated resource", str(contents))

    materializations = [
        action
        for action in target_actions
        if action.get("kind") == "symlinkeddir"
        and action.get("category") == "symlinked_dir"
        and "resources" in str(action.get("identifier", ""))
    ]
    if len(materializations) != 1:
        fail("generated resource materialization action was not unique")
    materialization = materializations[0]
    full_inputs = str(materialization.get("buck.all_ineligible_for_dedup_inputs", ""))
    if "nextest_generated_rust_runtime_resource" not in full_inputs:
        fail("resource materialization did not retain the generated resource input", full_inputs)

    generator_actions = load_aquery(buck, project, "//:nextest_generated_rust_runtime_resource")
    generator_runs = [
        action for action in generator_actions.values()
        if action.get("kind") == "run" and action.get("category") == "genrule"
    ]
    if len(generator_runs) != 1:
        fail("generated resource action was not unique")

    graph_text = json.dumps(actions, sort_keys=True).lower()
    forbidden = ("staging", "packaging", "runtime_destination", "runtime-destination")
    if any(value in graph_text for value in forbidden):
        fail("resource action graph contains a packaging or copied-runtime action", graph_text)


def check_production_command(buck: str, project: Path) -> None:
    temp_root = "/private/tmp" if sys.platform == "darwin" else "/tmp"
    with tempfile.TemporaryDirectory(prefix="buck2-nextest-provider.", dir=temp_root) as directory:
        root = Path(directory)
        caller = root / "caller"
        junit = caller / "junit"
        junit.mkdir(parents=True)
        events = root / "events.json-lines"
        executor_result = run([buck, "build", "--show-output", "//:nextest_v2_executor"], project)
        executor = executor_result.stdout.strip().splitlines()[-1].split(maxsplit=1)[-1]
        executor_path = Path(executor)
        if not executor_path.is_absolute():
            executor_path = project / executor_path
        command = [
            buck,
            "--isolation-dir",
            f"nextest-provider-contract-{os.getpid()}",
            "test",
            "--no-remote-cache",
            "--config",
            f"test.v2_test_executor={executor_path}",
            "--event-log",
            str(events),
            "--test-executor-stdout=-",
            "--test-executor-stderr=-",
            VALID_WRAPPER,
            "--",
            "--junit-dir",
            str(junit),
        ]
        result = run(command, project, check=False)
        if result.returncode != 0:
            fail("production valid wrapper did not pass", result.stdout, result.stderr)
        try:
            rows = [json.loads(line) for line in run([buck, "log", "what-ran", "--format", "json", "--no-remote", str(events)], project).stdout.splitlines() if line.strip()]
        except (subprocess.CalledProcessError, json.JSONDecodeError) as exc:
            fail(f"could not parse fresh what-ran evidence: {exc}")
        matches = [row for row in rows if row.get("reason") == "test.run" and row.get("identity") == VALID_WRAPPER[3:]]
        if len(matches) != 1:
            fail("fresh what-ran evidence did not contain exactly one production test action", json.dumps(rows))
        command_values = matches[0].get("reproducer", {}).get("details", {}).get("command")
        if not isinstance(command_values, list):
            fail("production test action had no structured command", json.dumps(matches[0]))
        command_values = [str(value) for value in command_values]
        declared = [command_values[index + 1] for index, value in enumerate(command_values) if value == "--declared-input" and index + 1 < len(command_values)]
        if len(declared) != 1 or "runtime_resource_positive_executable" not in declared[0]:
            fail("production command did not declare exactly the executable artifact", json.dumps(command_values))
        if any(value in " ".join(command_values).lower() for value in ("staging", "packaging", "runtime-destination", "runtime_destination")):
            fail("production command contains copied-runtime or packaging behavior", json.dumps(command_values))
        if len(list(junit.glob("*.xml"))) != 1:
            fail("production command did not publish exactly one JUnit report")


def check_invalid_analysis(buck: str, project: Path) -> None:
    result = run([buck, "build", "--no-remote-cache", INVALID_WRAPPER], project, check=False)
    combined = result.stdout + result.stderr
    if result.returncode == 0:
        fail("invalid executable unexpectedly analyzed")
    if MISSING_DISTINFO not in combined or "Found these providers: DefaultInfo, RunInfo" not in combined:
        fail("invalid executable failed for a reason other than missing DistInfo", combined)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} BUCK2 PROJECT_ROOT", file=sys.stderr)
        return 2
    buck, project_name = sys.argv[1:]
    project = Path(project_name).resolve()
    check_resource_materialization(buck, project)
    check_production_command(buck, project)
    check_invalid_analysis(buck, project)
    print("buck2 nextest runtime provider contract: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
