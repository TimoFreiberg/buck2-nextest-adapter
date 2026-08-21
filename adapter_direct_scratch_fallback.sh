#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-$(cd "$(dirname "$0")" && pwd -P)}
artifact=$1
manifest=$2
validator=$3
cargo_baseline=$4
binary_baseline=$5
tests_baseline=$6
run_root=$(mktemp -d "${TMPDIR:-/tmp}/direct-scratch-test.XXXXXX")
run_root=$(cd "$run_root" && pwd -P)
trap 'rm -rf "$run_root"' EXIT
scratch="$run_root/scratch"
mkdir "$scratch"
launcher="$run_root/launcher.py"
cat >"$launcher" <<'PY'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
if args[:2] == ["cargo", "nextest"]:
    args = args[1:]
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
profile = args[args.index("--profile") + 1]
target = Path(os.environ["CARGO_MANIFEST_DIR"]) / "target" / "nextest" / profile
target.mkdir(parents=True, exist_ok=True)
(target / "junit.xml").write_text('<testsuites><testsuite><testcase classname="fixture" name="pass_case" /></testsuite></testsuites>\n')
raise SystemExit(0)
PY
chmod +x "$launcher"
report="$run_root/report.xml"
out="$run_root/out"
if ! BUCK_SCRATCH_PATH= TMPDIR="$scratch" BUCK_DEFAULT_RUNTIME_RESOURCES="$root" \
    BUCK2_NEXTEST_DISPATCH_ALLOWED=1 \
    "$root/adapter.sh" buck-artifact --artifact "$artifact" --manifest "$manifest" \
    --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" \
    --tests-baseline "$tests_baseline" --cargo-command "$launcher" \
    --junit-report "$report" >"$out" 2>&1; then
    cat "$out" >&2
    exit 1
fi
[ -s "$report" ] || { cat "$out"; exit 1; }
private_root=$(sed -n 's/.*cleanup=once root=//p' "$out")
case "$private_root" in
    "$scratch"/*) ;;
    *) cat "$out" >&2; exit 1 ;;
esac
[ ! -e "$private_root" ]
[ "$(grep -c 'cleanup=once' "$out")" -eq 1 ]
printf '%s\n' 'adapter direct scratch fallback: passed'
