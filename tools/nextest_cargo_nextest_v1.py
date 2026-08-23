#!/usr/bin/python3
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
record_helper = os.environ.get("ADAPTER_RELOCATED_RECORD_HELPER")
record_dir = os.environ.get("ADAPTER_RELOCATED_RECORD_DIR")
if record_helper and record_dir and not os.path.isfile(record_helper):
    record_helper = os.path.join(os.environ.get("BUCK_PROJECT_ROOT", "."), "tools", "nextest_relocated_records.py")
if record_dir and record_helper:
    import subprocess
    subprocess.run(["/usr/bin/python3", record_helper, "write-fixture", sys.argv[0]], check=True)
log = os.environ.get("BUCK2_NEXTEST_ARGV_LOG")
marker = os.environ.get("BUCK2_NEXTEST_TOOL_MARKER")
if marker:
    Path(marker).write_text("v1\n", encoding="utf-8")
dispatch_log = os.environ.get("BUCK2_NEXTEST_DISPATCH_LOG")
if dispatch_log:
    with open(dispatch_log, "a", encoding="utf-8") as stream:
        stream.write("top-level cargo nextest dispatch: %s\n" % " ".join(args))
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
    print(f"recorder-v1 profile={profile} filter={filterset}")
    raise SystemExit(100)
(target / "junit.xml").write_text(
    '<testsuites><testsuite><testcase classname="fixture" name="pass_case" /></testsuite></testsuites>\n',
    encoding="utf-8",
)
print(f"recorder-v1 profile={profile} filter={filterset}")
raise SystemExit(0)
