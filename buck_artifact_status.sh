#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
case_name=$1
shift
artifact=$1
manifest=$2
validator=$3
cargo_baseline=$4
binary_baseline=$5
tests_baseline=$6
tmp=$(mktemp -d "./.buck2-nextest-test.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
report=$tmp/report.xml
out=$tmp/out
if [ "$case_name" = timeout ]; then
    python3_bin=$(command -v python3 || true)
    if [ -z "$python3_bin" ] || ! "$python3_bin" - <<'PY' >/dev/null 2>&1
import tomllib
PY
    then
        printf '%s\n' 'timeout profile test requires Python 3.11+ with tomllib' >&2
        exit 1
    fi
    marker=$tmp/timeout-readiness/marker
    capture=$tmp/timeout-profile.toml
    mkdir -p "$(dirname "$marker")"
    rm -f "$marker"
    [ ! -e "$marker" ]
    run_timeout() {
        readiness=$1
        destination=$2
        output=$3
        profile_capture=$4
        timing=$5
        if [ -n "$readiness" ]; then
            export BUCK2_NEXTEST_TIMEOUT_READINESS=$readiness
        else
            unset BUCK2_NEXTEST_TIMEOUT_READINESS
        fi
        if [ -n "$profile_capture" ]; then
            export BUCK2_NEXTEST_PROFILE_CAPTURE=$profile_capture
        else
            unset BUCK2_NEXTEST_PROFILE_CAPTURE
        fi
        set +e
        "$python3_bin" - "$timing" "$output" "$root/adapter.sh" buck-artifact --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --junit-report "$destination" --scenario timeout <<'PY'
import os
import subprocess
import sys
import time
from pathlib import Path

timing, output, *argv = sys.argv[1:]
env = os.environ.copy()
with open(output, "wb") as stream:
    started = time.monotonic_ns()
    completed = subprocess.run(argv, stdout=stream, stderr=subprocess.STDOUT, env=env)
    elapsed = time.monotonic_ns() - started
Path(timing).write_text(str(elapsed), encoding="ascii")
sys.exit(completed.returncode)
PY
        status=$?
        return "$status"
    }
    set +e
    run_timeout "$marker" "$report" "$out" "$capture" "$tmp/elapsed"
    status=$?
    set -e
    [ "$status" -eq 100 ] || { cat "$out"; printf 'expected timeout status 100, got %s\n' "$status" >&2; exit 1; }
    [ -s "$marker" ]
    [ -s "$report" ]
    elapsed_ns=$(cat "$tmp/elapsed")
    [ "$elapsed_ns" -gt 1000000000 ] && [ "$elapsed_ns" -lt 8000000000 ] || { printf 'timeout elapsed outside bounds: %s ns\n' "$elapsed_ns" >&2; cat "$out"; exit 1; }
    "$python3_bin" - "$capture" <<'PY'
import sys
import tomllib
from pathlib import Path
value = tomllib.loads(Path(sys.argv[1]).read_text())
assert set(value) == {"profile"}
assert set(value["profile"]) == {"ci"}
assert set(value["profile"]["ci"]) == {"slow-timeout", "junit"}
assert value["profile"]["ci"]["slow-timeout"] == {"period": "1s", "terminate-after": 1, "grace-period": "0s"}
assert value["profile"]["ci"]["junit"] == {"path": "junit.xml"}
text = Path(sys.argv[1]).read_text()
assert text.index("[profile.ci]") < text.index('slow-timeout = { period = "1s", terminate-after = 1, grace-period = "0s" }') < text.index("[profile.ci.junit]")
assert text.index('path = "junit.xml"') > text.index("[profile.ci.junit]")
assert "report-skipped" not in text
PY
    second_report=$tmp/second-report.xml
    second_marker=$tmp/second-readiness/marker
    mkdir -p "$(dirname "$second_marker")"
    rm -f "$second_marker" "$second_report"
    set +e
    run_timeout "" "$second_report" "$tmp/second-out" "" "$tmp/second-elapsed"
    second_status=$?
    set -e
    [ "$second_status" -eq 100 ] || { cat "$tmp/second-out"; exit 1; }
    [ -s "$second_report" ] && [ ! -e "$second_marker" ]
    python3 - "$report" "$second_report" <<'PY'
import sys
import xml.etree.ElementTree as ET
for path in sys.argv[1:]:
    root = ET.parse(path).getroot()
    cases = root.findall('.//testcase')
    assert [c.get('name') for c in cases] == ['timeout_case']
    assert [child.tag for child in cases[0] if child.tag in {'failure', 'error', 'skipped'}] == ['failure']
    assert not root.findall('.//timeout')
    assert not root.findall('.//adapter-summary')
PY
    ! grep -F 'adapter-timeout' "$out"
    fi
if [ "$case_name" != timeout ]; then
    set +e
    "$root/adapter.sh" buck-artifact --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --junit-report "$report" --scenario "$case_name" >"$out" 2>&1
    status=$?
    set -e
fi
case "$case_name" in
    timeout)
        ;;
    ignored)
        [ "$status" -eq 0 ] || { cat "$out"; exit 1; }
        [ -s "$report" ]
        python3 - "$report" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = root.findall('.//testcase')
assert [c.get('name') for c in cases] == ['ignored_case']
assert [child.tag for child in cases[0] if child.tag in {'failure', 'error', 'skipped'}] == ['skipped']
PY
        ;;
    filtered)
        [ "$status" -eq 0 ] || { cat "$out"; exit 1; }
        [ -s "$report" ]
        python3 - "$report" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = root.findall('.//testcase')
assert [c.get('name') for c in cases] == ['pass_case']
assert [child.tag for child in cases[0] if child.tag in {'failure', 'error', 'skipped'}] == []
PY
        ;;
    no-tests)
        [ "$status" -eq 4 ] || { cat "$out"; printf 'expected status 4, got %s\n' "$status" >&2; exit 1; }
        if [ -e "$report" ]; then
            python3 - "$report" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
assert root.findall('.//testcase') == []
PY
        fi
        ;;
    *) printf 'unknown status subcase: %s\n' "$case_name" >&2; exit 2 ;;
esac
[ "$(grep -c 'cleanup=once' "$out")" -eq 1 ]
private_root=$(sed -n 's/.*cleanup=once root=//p' "$out")
[ -n "$private_root" ] && [ ! -e "$private_root" ]
printf 'buck artifact status %s: passed\n' "$case_name"
