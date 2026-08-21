#!/usr/bin/env python3
import json
import os
import signal
import sys
import time
from pathlib import Path

args = sys.argv[1:]
if args[:2] == ["nextest", "run"] and "--help" in args:
    print("--filterset --profile --no-tests --cargo-metadata --binaries-metadata --target-dir-remap --workspace-remap --build-dir-remap --success-output --failure-output")
    raise SystemExit(0)
if args[:2] == ["nextest", "list"] and "--help" in args:
    print("--cargo-metadata --binaries-metadata --target-dir-remap --workspace-remap --build-dir-remap")
    raise SystemExit(0)
if args[:2] == ["nextest", "list"]:
    for name in ("pass_case", "fail_case", "ignored_case", "timeout_case"):
        print(json.dumps({"binary_id": "buck2_nextest_rust_test", "test_name": name}))
    raise SystemExit(0)
if args[:2] != ["nextest", "run"]:
    raise SystemExit("unexpected cargo-nextest argv")

pid_path = Path(os.environ["BUCK2_NEXTEST_SIGNAL_PID"])
ready_path = Path(os.environ["BUCK2_NEXTEST_SIGNAL_READY"])
terminated_path = Path(os.environ["BUCK2_NEXTEST_SIGNAL_TERMINATED"])
profile = args[args.index("--profile") + 1]
target = Path(os.environ["CARGO_MANIFEST_DIR"]) / "target" / "nextest" / profile
target.mkdir(parents=True, exist_ok=True)
state = {"terminated": False}

def terminate(signum, _frame):
    if not state["terminated"]:
        state["terminated"] = True
        terminated_path.write_text("signal-fixture=terminated\n", encoding="utf-8")
        (target / "junit.xml").write_text('<testsuites><testsuite><testcase classname="fixture" name="pass_case" /></testsuite></testsuites>\n', encoding="utf-8")
    raise SystemExit(0)

signal.signal(signal.SIGTERM, terminate)
signal.signal(signal.SIGINT, terminate)
pid_path.write_text(f"{os.getpid()}\n", encoding="utf-8")
ready_path.write_text("signal-fixture=ready\n", encoding="utf-8")
while True:
    time.sleep(1)
