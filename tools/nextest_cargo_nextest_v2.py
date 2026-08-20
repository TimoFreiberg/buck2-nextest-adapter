#!/usr/bin/python3
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
log = os.environ.get("BUCK2_NEXTEST_ARGV_LOG")
marker = os.environ.get("BUCK2_NEXTEST_TOOL_MARKER")
if marker:
    Path(marker).write_text("v2\n", encoding="utf-8")
if log:
    with open(log, "a", encoding="utf-8") as stream:
        json.dump(args, stream, ensure_ascii=False)
        stream.write("\n")

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
profile = args[args.index("--profile") + 1]
filterset = args[args.index("--filterset") + 1]
target = Path(os.environ["CARGO_MANIFEST_DIR"]) / "target" / "nextest" / profile
(target).mkdir(parents=True, exist_ok=True)
if filterset == "test(=fail_case)":
    (target / "junit.xml").write_text(
        '<testsuites><testsuite><testcase classname="fixture" name="fail_case"><failure /></testcase></testsuite></testsuites>\n',
        encoding="utf-8",
    )
    print(f"recorder-v2 profile={profile} filter={filterset}")
    raise SystemExit(100)
(target / "junit.xml").write_text(
    '<testsuites><testsuite><testcase classname="fixture" name="pass_case" /></testsuite></testsuites>\n',
    encoding="utf-8",
)
print(f"recorder-v2 profile={profile} filter={filterset}")
raise SystemExit(0)
