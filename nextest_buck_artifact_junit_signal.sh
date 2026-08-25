#!/bin/sh
set -eu
runner=${1:-}
fixture=${2:-}
artifact_target=${3:-}
manifest=${4:-}
cargo_baseline=${5:-}
binary_baseline=${6:-}
tests_baseline=${7:-}
runtime_resource=${8:-}
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-$(cd "$(dirname "$0")" && pwd -P)}
[ -n "$runner" ] && [ -x "$runner" ]
[ -n "$fixture" ] && [ -x "$fixture" ]
[ -n "$artifact_target" ] && [ -n "$manifest" ] && [ -n "$cargo_baseline" ] && [ -n "$binary_baseline" ] && [ -n "$tests_baseline" ] && [ -n "$runtime_resource" ]
run_root=$(mktemp -d "${TMPDIR:-/tmp}/nextest-signal.XXXXXX")
trap 'if [ -n "${adapter_pid:-}" ]; then kill -TERM "$adapter_pid" 2>/dev/null || true; fi; rm -rf "$run_root"' EXIT INT TERM
pid_file="$run_root/signal-fixture.pid"
child_pid_file="$run_root/signal-fixture.child.pid"
grandchild_pid_file="$run_root/signal-fixture.grandchild.pid"
ready="$run_root/signal-fixture.ready"
terminated="$run_root/signal-fixture.terminated"
child_terminated="$run_root/signal-fixture.child.terminated"
grandchild_terminated="$run_root/signal-fixture.grandchild.terminated"
report="$run_root/report.xml"
out="$run_root/out"
# Buck's declared output parent is a real directory in the action sandbox;
# export into it rather than the test-owned scratch directory.
mkdir -p "$run_root/output"
report="$run_root/output/report.xml"
: >"$pid_file"; : >"$ready"; : >"$terminated"
# The declared-output target is intentionally used only to identify the action; the
# signal path runs the same adapter boundary with declared fixture inputs below.
artifact=$artifact_target
if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$runtime_resource" | awk '{print $1}')
else
    digest=$(shasum -a 256 "$runtime_resource" | awk '{print $1}')
fi
size=$(wc -c <"$runtime_resource" | tr -d ' ')
bundle_json=$(printf '%s' '{"bundle_environment":[{"kind":"relative_path","name":"BUCK2_BUNDLE_RESOURCE","value":"runtime/fixture-resource.txt"}],"bundle_platform":"signal-fixture-v1","bundle_resources":[{"digest":"sha256:'"$digest"':'"$size"'","path":"runtime/fixture-resource.txt","source":"'"$(basename "$runtime_resource")"'"}],"bundle_version":1}')
set +e
BUCK_SCRATCH_PATH="buck-out/v2/tmp/signal-fixture" NEXTEST_SIGNAL_PID="$pid_file" NEXTEST_SIGNAL_CHILD_PID="$child_pid_file" \
NEXTEST_SIGNAL_GRANDCHILD_PID="$grandchild_pid_file" NEXTEST_SIGNAL_READY="$ready" \
NEXTEST_SIGNAL_TERMINATED="$terminated" NEXTEST_SIGNAL_CHILD_TERMINATED="$child_terminated" \
NEXTEST_SIGNAL_GRANDCHILD_TERMINATED="$grandchild_terminated" \
"$runner" buck-artifact --build-mode --artifact "$artifact" --manifest "$manifest" \
    --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" \
    --cargo-nextest-argv "$fixture" --end-argv --bundle-json "$bundle_json" \
    --bundle-resources "$runtime_resource" --end-bundle-resources --runtime-resource "$runtime_resource" \
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
[ -s "$child_pid_file" ]
[ -s "$grandchild_pid_file" ]
fixture_pid=$(cat "$pid_file")
child_pid=$(cat "$child_pid_file")
grandchild_pid=$(cat "$grandchild_pid_file")
kill -0 "$fixture_pid"
kill -0 "$child_pid"
kill -0 "$grandchild_pid"
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
! kill -0 "$child_pid" 2>/dev/null
! kill -0 "$grandchild_pid" 2>/dev/null
[ "$(cat "$terminated")" = 'signal-fixture=terminated' ]
[ "$(cat "$child_terminated")" = 'signal-fixture-child=terminated' ]
[ "$(cat "$grandchild_terminated")" = 'signal-fixture-grandchild=terminated' ]
# The Rust runner owns cleanup; the test must not rely on a legacy shell log.
[ ! -d "buck-out/v2/tmp/signal-fixture" ] || ! find buck-out/v2/tmp/signal-fixture -mindepth 1 -maxdepth 1 -type d -name 'buck2-nextest-buck-artifact.*' -print -quit | grep -q .
printf '%s\n' "declared JUnit signal cleanup: passed adapter-status=$adapter_status"
