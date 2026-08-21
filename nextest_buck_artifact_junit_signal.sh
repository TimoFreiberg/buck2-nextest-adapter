#!/bin/sh
set -eu
fixture=${1:-}
artifact_target=${2:-}
manifest=${3:-}
validator=${4:-}
cargo_baseline=${5:-}
binary_baseline=${6:-}
tests_baseline=${7:-}
runtime_resource=${8:-}
source_denial=${9:-}
metadata_parser=${10:-}
python_command=${11:-}
if ! command -v setsid >/dev/null 2>&1; then
    printf '%s\n' 'declared JUnit signal cleanup: BLOCKED (setsid/process groups unavailable)' >&2
    exit 0
fi
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-$(cd "$(dirname "$0")" && pwd -P)}
[ -n "$fixture" ] && [ -x "$fixture" ]
[ -n "$artifact_target" ] && [ -n "$manifest" ] && [ -n "$validator" ] && [ -n "$cargo_baseline" ] && [ -n "$binary_baseline" ] && [ -n "$tests_baseline" ] && [ -n "$runtime_resource" ] && [ -n "$source_denial" ] && [ -n "$metadata_parser" ] && [ -n "$python_command" ]
run_root=$(mktemp -d "${TMPDIR:-/tmp}/nextest-signal.XXXXXX")
trap 'if [ -n "${adapter_pid:-}" ]; then kill -TERM "$adapter_pid" 2>/dev/null || true; fi; rm -rf "$run_root"' EXIT INT TERM
pid_file="$run_root/signal-fixture.pid"
ready="$run_root/signal-fixture.ready"
terminated="$run_root/signal-fixture.terminated"
report="$run_root/report.xml"
out="$run_root/out"
: >"$pid_file"; : >"$ready"; : >"$terminated"
# The declared-output target is intentionally used only to identify the action; the
# signal path runs the same adapter boundary with declared fixture inputs below.
artifact=$artifact_target
set +e
BUCK2_NEXTEST_REQUIRE_PROCESS_GROUP=1 BUCK2_NEXTEST_SIGNAL_PID="$pid_file" \
BUCK2_NEXTEST_SIGNAL_READY="$ready" BUCK2_NEXTEST_SIGNAL_TERMINATED="$terminated" \
"$root/adapter.sh" buck-artifact --build-mode --artifact "$artifact" --manifest "$manifest" \
    --validator "$validator" --cargo-baseline "$cargo_baseline" \
    --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" \
    --cargo-command "$source_denial" --python-command "$python_command" \
    --cargo-nextest-command "$fixture" nextest --runtime-resource "$runtime_resource" \
    --source-denial "$source_denial" --action-metadata-parser "$metadata_parser" \
    --junit-report "$report" >"$out" 2>&1 &
adapter_pid=$!
set -e
for _ in $(seq 1 50); do
    [ -s "$ready" ] && break
    kill -0 "$adapter_pid" 2>/dev/null || { cat "$out" >&2; exit 1; }
    sleep .1
done
[ -s "$ready" ] || { cat "$out" >&2; exit 1; }
[ -s "$pid_file" ]
fixture_pid=$(cat "$pid_file")
kill -0 "$fixture_pid"
kill -TERM "$adapter_pid"
adapter_status=1
for _ in $(seq 1 50); do
    if ! kill -0 "$adapter_pid" 2>/dev/null; then
        wait "$adapter_pid" 2>/dev/null || adapter_status=$?
        break
    fi
    sleep .1
done
! kill -0 "$adapter_pid" 2>/dev/null
! kill -0 "$fixture_pid" 2>/dev/null
[ "$(cat "$terminated")" = 'signal-fixture=terminated' ]
[ "$(grep -c 'cleanup=once' "$out")" -eq 1 ]
printf '%s\n' "declared JUnit signal cleanup: passed adapter-status=$adapter_status"
