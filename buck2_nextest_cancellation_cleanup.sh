#!/bin/sh
set -eu

project=${BUCK_PROJECT_ROOT:-$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)}
buck=${BUCK2:-buck2}
case "$(uname -s)" in
    Darwin|Linux) ;;
    *) printf '%s\n' 'schema-v2 cancellation: unsupported host OS' >&2; exit 2 ;;
esac
command -v ps >/dev/null 2>&1 || { printf '%s\n' 'schema-v2 cancellation: ps is required' >&2; exit 2; }
python3 - <<'PY'
import os
try:
    os.setsid()
except OSError as exc:
    raise SystemExit(f"schema-v2 cancellation: session creation unavailable: {exc}")
PY

executor=$($buck build --show-output //:nextest_v2_executor | tail -1 | cut -d' ' -f2)
case "$executor" in /*) ;; *) executor="$project/$executor" ;; esac
executor=$(CDPATH= cd -- "$(dirname "$executor")" && pwd -P)/$(basename "$executor")
case "$(uname -s)" in
    Darwin) temp_root=/private/tmp ;;
    Linux) temp_root=/tmp ;;
esac
root=$(mktemp -d "$temp_root/buck2-nextest-cancel.XXXXXX")
root=$(CDPATH= cd -- "$root" && pwd -P)
caller="$root/caller"
control="$root/control"
observation="$control/observation"
tmp_parent="$control/tmp"
retain_root=0
cleanup() {
    if [ "$retain_root" -eq 0 ]; then
        rm -rf "$root"
    else
        printf '%s\n' "schema-v2 cancellation: retained diagnostics at $root" >&2
    fi
}
trap cleanup EXIT HUP INT TERM
mkdir "$caller" "$control" "$caller/junit" "$observation" "$tmp_parent"
export TMPDIR="$tmp_parent"
nonce="cancel-$$-$(date +%s)"
events="$control/events.json-lines"
output="$control/output"

process_row() {
    pid=$1
    ps -p "$pid" -o pid=,ppid=,pgid=,lstart=,command= | awk 'NF >= 5 { print; found=1 } END { exit(found ? 0 : 1) }'
}
process_start() {
    ps -p "$1" -o pid=,lstart= | awk '{ $1=""; sub(/^ /, ""); print }'
}
process_pgid() {
    ps -p "$1" -o pgid= | sed 's/^ *//'
}
process_live() {
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null && [ "$(ps -p "$1" -o state= | tr -d ' ')" != Z ]
}
process_identity_live() {
    [ "$(process_start "$1")" = "$2" ] && process_live "$1"
}

# Python supplies setsid as the child pre-exec hook while the shell retains
# ownership of the Buck PID for a reliable wait(1) and status result.
python3 - "$buck" "$executor" "$root" "$events" "$nonce" "$project" <<'PY' >"$control/launcher.pid" 2>"$control/launcher.err" &
import os, subprocess, sys
buck, executor, root, events, nonce, project = sys.argv[1:]
output = open(f"{root}/buck.output", "wb", buffering=0)
child = subprocess.Popen([
    buck, "--isolation-dir", f"nextest-cancel-{os.getpid()}",
    "test", "--config", f"test.v2_test_executor={executor}",
    "--config", f"nextest_test.observation_dir={root}/control/observation",
    "--config", f"nextest_test.nonce={nonce}",
    "--event-log", events,
    "--test-executor-stdout=-", "--test-executor-stderr=-",
    "//:nextest_buck_test_cancellation", "--", "--junit-dir", f"{root}/caller/junit",
], cwd=project, stdout=output, stderr=subprocess.STDOUT, preexec_fn=os.setsid)
print(child.pid, flush=True)
raise SystemExit(child.wait())
PY
launcher_parent=$!
for _ in $(seq 1 100); do
    launcher_pid=$(sed -n 's/^[0-9][0-9]*$/&/p' "$control/launcher.pid" 2>/dev/null | head -n 1 || true)
    [ -n "$launcher_pid" ] && break
    process_live "$launcher_parent" || { cat "$control/launcher.err" >&2; exit 1; }
    sleep .01
done
[ -n "${launcher_pid:-}" ] || { cat "$control/launcher.err" >&2; exit 1; }
launcher_pgid=$(process_pgid "$launcher_pid")
launcher_start=$(process_start "$launcher_pid")
[ "$launcher_pgid" = "$launcher_pid" ] || { cat "$control/launcher.err" >&2; cat "$control/buck.output" >&2 2>/dev/null || true; printf '%s\n' 'schema-v2 cancellation: launcher did not create a private session' >&2; exit 1; }

state="$observation/state.json"
for _ in $(seq 1 300); do
    if [ -f "$state" ]; then break; fi
    process_live "$launcher_pid" || { cat "$root/buck.output" >&2; exit 1; }
    sleep .1
done
[ -f "$state" ] || { cat "$root/buck.output" >&2; printf '%s\n' 'schema-v2 cancellation: readiness state missing' >&2; exit 1; }

python3 - "$state" "$nonce" <<'PY'
import json, sys
from pathlib import Path
value = json.loads(Path(sys.argv[1]).read_text())
if set(value) != {"schema", "nonce", "test_pid", "test_start_identity", "ready"}:
    raise SystemExit("schema-v2 cancellation: state has unknown or missing fields")
if value["schema"] != 1 or value["nonce"] != sys.argv[2] or value["ready"] is not True:
    raise SystemExit("schema-v2 cancellation: state does not match invocation")
if not isinstance(value["test_pid"], int) or not isinstance(value["test_start_identity"], str) or not value["test_start_identity"]:
    raise SystemExit("schema-v2 cancellation: state identity is invalid")
PY

test_pid=$(python3 - "$state" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["test_pid"])
PY
)
test_start=$(process_start "$test_pid")
[ "$test_start" = "$(python3 - "$state" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["test_start_identity"])
PY
)" ] || { printf '%s\n' 'schema-v2 cancellation: test PID identity changed' >&2; exit 1; }
for _ in $(seq 1 300); do
    runner_name="nextest_""buck_test"
    runner_rows=$(ps -axo pid=,ppid=,pgid=,command= | awk -v session="$launcher_pgid" -v name="$runner_name" -v nonce="$nonce" '(index($0, name " ") || index($0, "/" name " ")) && index($0, nonce) { if ($3 != session) print }')
    runner_count=$(printf '%s\n' "$runner_rows" | sed '/^$/d' | wc -l | tr -d ' ')
    if [ "$runner_count" -gt 1 ]; then
        printf '%s\n' "$runner_rows" >&2
        cat "$control/buck.output" >&2 2>/dev/null || true
        printf '%s\n' 'schema-v2 cancellation: runner identity is ambiguous' >&2
        exit 1
    fi
    if [ "$runner_count" -eq 1 ]; then
        runner_pid=$(printf '%s\n' "$runner_rows" | awk '{ print $1 }')
        nextest_rows=$(ps -axo pid=,ppid=,pgid=,command= | awk -v parent="$runner_pid" '$2 == parent && /cargo-nextest/ { print }')
        nextest_count=$(printf '%s\n' "$nextest_rows" | sed '/^$/d' | wc -l | tr -d ' ')
        if [ "$nextest_count" -gt 1 ]; then
            printf '%s\n' 'schema-v2 cancellation: nextest identity is ambiguous' >&2
            exit 1
        fi
        if [ "$nextest_count" -eq 1 ]; then
            nextest_pid=$(printf '%s\n' "$nextest_rows" | awk '{ print $1 }')
            process_row "$runner_pid" >/dev/null || { printf '%s\n' 'schema-v2 cancellation: runner identity is not inspectable' >&2; exit 1; }
            process_row "$nextest_pid" >/dev/null || { printf '%s\n' 'schema-v2 cancellation: nextest identity is not inspectable' >&2; exit 1; }
            runner_start=$(process_start "$runner_pid")
            nextest_start=$(process_start "$nextest_pid")
            nextest_pgid=$(process_pgid "$nextest_pid")
            [ "$nextest_pgid" = "$(process_pgid "$runner_pid")" ] || { printf '%s\n' 'schema-v2 cancellation: nextest escaped the runner action group' >&2; exit 1; }
            break
        fi
    fi
    process_live "$launcher_pid" || { cat "$control/buck.output" >&2 2>/dev/null || true; printf '%s\n' 'schema-v2 cancellation: process exited before nextest readiness' >&2; exit 1; }
    sleep .1
done
[ -n "${nextest_pid:-}" ] || { cat "$control/buck.output" >&2 2>/dev/null || true; printf '%s\n' 'schema-v2 cancellation: nextest readiness missing' >&2; exit 1; }

runner_pgid=$(process_pgid "$runner_pid")
nextest_pgid=$(process_pgid "$nextest_pid")
kill -TERM -- "-$launcher_pgid"
set +e
wait "$launcher_parent"
status=$?
set -e
[ "$status" -ne 0 ] || { cat "$root/buck.output" >&2; printf '%s\n' 'schema-v2 cancellation: Buck unexpectedly passed' >&2; exit 1; }
for pid in "$launcher_pid" "$test_pid" "$runner_pid" "$nextest_pid"; do
    case "$pid" in
        "$runner_pid") start="$runner_start" ;;
        "$nextest_pid") start="$nextest_start" ;;
        *) start="$(process_start "$pid" 2>/dev/null || true)" ;;
    esac
    for _ in $(seq 1 100); do
        process_identity_live "$pid" "$start" || break
        sleep .1
    done
    ! process_identity_live "$pid" "$start" || { retain_root=1; printf 'schema-v2 cancellation: process survived pid=%s\n' "$pid" >&2; cat "$root/buck.output" >&2 2>/dev/null || true; exit 1; }
done
[ ! -e "$caller/junit/junit.xml" ] || { printf '%s\n' 'schema-v2 cancellation: report was committed after cancellation' >&2; exit 1; }
[ "$(find "$caller/junit" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" -eq 0 ] || { printf '%s\n' 'schema-v2 cancellation: caller directory is not empty' >&2; exit 1; }
[ "$(find "$tmp_parent" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" -eq 0 ] || { printf '%s\n' 'schema-v2 cancellation: invocation scratch leaked' >&2; exit 1; }
[ "$(find "$observation" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" -eq 1 ] || { printf '%s\n' 'schema-v2 cancellation: observation state changed unexpectedly' >&2; exit 1; }
printf '%s\n' "buck2 nextest cancellation cleanup: passed status=$status"
