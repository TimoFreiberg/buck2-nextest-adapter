#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)
gate="$root/nextest_buck_artifact_remote.sh"
run_root=$(mktemp -d "${TMPDIR:-/tmp}/nextest-remote-selftest.XXXXXX")
trap 'rm -rf "$run_root"' EXIT
project="$run_root/project"
mkdir -p "$project/buck-out"
config="$run_root/re.conf"
platform='external//:remote-platform'
printf '%s\n' '[buck2_re_client]' 'secret = never-print-this-value' >"$config"

stub="$run_root/buck2-stub"
cat >"$stub" <<'PY'
#!/usr/bin/env python3
import os
import shlex
import sys
import time
from pathlib import Path

args = sys.argv[1:]
log = os.environ.get("BUCK2_NEXTEST_STUB_ARGV_LOG")
if log:
    with open(log, "a", encoding="utf-8") as f:
        f.write(shlex.join(args) + "\n")
mode = os.environ.get("BUCK2_NEXTEST_STUB_MODE", "success")
if mode == "signal" and "build" in args:
    time.sleep(30)
if mode == "buck-failure" and "build" in args:
    print("secret=never-print-this-value", file=sys.stderr)
    raise SystemExit(17)
if mode.startswith("audit-") and "audit" in args:
    if mode == "audit-missing-cell":
        raise SystemExit(9)
    label = os.environ.get("BUCK2_NEXTEST_RE_EXECUTION_PLATFORM_LABEL", "external//:remote-platform")
    remote = "False" if mode == "audit-local" else "True"
    resolved = "external//:wrong-platform" if mode == "audit-wrong-platform" else label
    print(f"platform={resolved}\tremote_enabled={remote}\tlocal_enabled=False\tcommand_executor=buck2-re")
    raise SystemExit(0)
if "--help" in args:
    if "what-ran" in args:
        print("--emit-cache-queries --filter-category")
    elif "what-materialized" in args:
        print("--format")
    elif "build" in args:
        print("--show-output")
    else:
        print("--remote-only --no-remote-cache --isolation-dir --event-log")
    raise SystemExit(0)
if "audit" in args:
    print("platform=external//:remote-platform\tremote_enabled=True\tlocal_enabled=False\tcommand_executor=buck2-re")
    raise SystemExit(0)
if "build" in args:
    isolation = args[args.index("--isolation-dir") + 1]
    project = Path(os.environ["BUCK_PROJECT_ROOT"])
    output = project / "buck-out" / Path(isolation).name / "junit.xml"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text('<testsuite><testcase name="pass_case"/></testsuite>\n', encoding="utf-8")
    if "--event-log" in args:
        event_log = Path(args[args.index("--event-log") + 1])
        event_log.write_text("event\n", encoding="utf-8")
        destination = Path(os.environ["BUCK2_NEXTEST_STUB_OUTPUT"])
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(output.read_text(encoding="utf-8"), encoding="utf-8")
    print(f"//:nextest_buck_artifact_junit {output}")
    raise SystemExit(0)
if "what-ran" in args:
    identity = "root//:nextest_buck_artifact_junit"
    if mode == "local":
        executor = "local"
    else:
        executor = "RE"
    rows = 2 if mode == "duplicate" else 1
    if mode == "near-match":
        target_identity = "root//:nextest_buck_artifact_junit_extra"
    else:
        target_identity = identity
    target_suffix = " (nextest_buck_artifact_junit)" if mode != "near-match" else " (nextest_buck_artifact_junit_extra)"
    if mode == "cache-only":
        print(f"build\t{target_identity}{target_suffix}\tRE\tcache-hit")
    elif mode == "parse-failure":
        print("not a recognized what-ran record")
    else:
        for _ in range(rows):
            print(f"build\t{target_identity}{target_suffix}\t{executor}\tremote-action")
    raise SystemExit(0)
if "what-materialized" in args:
    project = Path(os.environ["BUCK_PROJECT_ROOT"])
    isolation = args[args.index("--isolation-dir") + 1]
    output = project / "buck-out" / Path(isolation).name / "junit.xml"
    if mode != "missing-materialization":
        print(f"{os.path.realpath(str(output))}\tcopy\t1\t48")
    raise SystemExit(0)
raise SystemExit(0)
PY
chmod 700 "$stub"

run() {
    mode=$1
    expected=$2
    shift 2
    argv_log="$run_root/argv-$mode.log"
    : >"$argv_log"
    set +e
    output=$(BUCK2="$stub" BUCK_PROJECT_ROOT="$project" \
        BUCK2_NEXTEST_RE_CONFIG_FILE="$config" \
        BUCK2_NEXTEST_RE_EXECUTION_PLATFORM_LABEL="$platform" \
        BUCK2_NEXTEST_STUB_MODE="$mode" \
        BUCK2_NEXTEST_STUB_ARGV_LOG="$argv_log" \
        BUCK2_NEXTEST_STUB_OUTPUT="$project/buck-out/$mode/junit.xml" \
        BUCK2_NEXTEST_REMOTE_SELFTEST=1 \
        "$gate" 2>"$run_root/stderr-$mode.log")
    status=$?
    set -e
    printf '%s\n' "$output" | grep -F "$expected" >/dev/null || {
        printf 'self-test case %s: unexpected output/status=%s\n' "$mode" "$status" >&2
        exit 1
    }
    [ "$status" -eq 0 ] && [ "$expected" = 'remote-selftest=passed' ] && return 0
    [ "$status" -ne 0 ] || { printf 'self-test case %s unexpectedly passed\n' "$mode" >&2; exit 1; }
}

# No configuration is the sole successful blocked result and must not invoke Buck.
no_config_log="$run_root/no-config.log"
set +e
output=$(BUCK2="$run_root/does-not-exist" BUCK2_NEXTEST_STUB_ARGV_LOG="$no_config_log" \
    env -u BUCK2_NEXTEST_RE_CONFIG_FILE -u BUCK2_NEXTEST_RE_EXECUTION_PLATFORM_LABEL \
    "$gate" 2>"$run_root/no-config.err")
status=$?
set -e
[ "$status" -eq 0 ]
printf '%s\n' "$output" | grep -F 'remote-gate=blocked-no-backend' >/dev/null
[ ! -s "$no_config_log" ]

# Input validation happens before Buck invocation.
set +e
output=$(BUCK2="$stub" BUCK2_NEXTEST_RE_CONFIG_FILE="$run_root/missing" \
    BUCK2_NEXTEST_RE_EXECUTION_PLATFORM_LABEL="$platform" "$gate" 2>/dev/null)
status=$?
set -e
[ "$status" -ne 0 ]
printf '%s\n' "$output" | grep -F 'remote-gate=invalid-input' >/dev/null

run success 'remote-selftest=passed'
printf '%s\n' 'remote self-test positive case is parser/control-flow coverage only; it is not remote execution evidence'
for mode in audit-missing-cell audit-wrong-platform audit-local buck-failure local cache-only duplicate near-match parse-failure missing-materialization; do
    case "$mode" in
        audit-*) expected='remote-gate=' ;;
        *) expected='remote-gate=' ;;
    esac
    run "$mode" "$expected"
done

log="$run_root/argv-success.log"
grep -F -- '--remote-only' "$log" >/dev/null
grep -F -- '--no-remote-cache' "$log" >/dev/null
grep -F -- '--emit-cache-queries' "$log" >/dev/null
grep -F -- '--filter-category' "$log" >/dev/null
grep -F -- 'nextest_buck_artifact_junit$' "$log" >/dev/null
grep -F -- '--config-file' "$log" >/dev/null
! grep -F 'never-print-this-value' "$run_root/stderr-success.log" "$run_root"/*.out 2>/dev/null || true

# A configured signal is a failure and the gate must not leave its private run root.
set +e
BUCK2="$stub" BUCK_PROJECT_ROOT="$project" BUCK2_NEXTEST_RE_CONFIG_FILE="$config" \
    BUCK2_NEXTEST_RE_EXECUTION_PLATFORM_LABEL="$platform" BUCK2_NEXTEST_STUB_MODE=signal \
    "$gate" >"$run_root/signal.out" 2>"$run_root/signal.err" &
pid=$!
sleep 1
kill -TERM "$pid" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
done
if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
fi
wait "$pid" 2>/dev/null || status=$?
status=${status:-0}
set -e
[ "$status" -ne 0 ]
! grep -F 'never-print-this-value' "$run_root/signal.out" "$run_root/signal.err" >/dev/null

printf '%s\n' 'remote gate self-test: passed (control-flow only; no RE backend)'
