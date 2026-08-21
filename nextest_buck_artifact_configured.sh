#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
artifact=$1
manifest=$2
validator=$3
cargo_baseline=$4
binary_baseline=$5
tests_baseline=$6
tmp=$(mktemp -d "./.buck2-nextest-configured.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
recorder=$root/nextest_test_recorder.py
[ -f "$recorder" ] || recorder="$root/../nextest_test_recorder.py"
recorder=$(cd "$(dirname "$recorder")" && pwd -P)/$(basename "$recorder")
python_launcher=$root/tools/nextest_python_launcher.sh
[ -x "$python_launcher" ] || python_launcher="$root/../tools/nextest_python_launcher.sh"
python_launcher=$(cd "$(dirname "$python_launcher")" && pwd -P)/$(basename "$python_launcher")
log=$tmp/argv.jsonl
capture=$tmp/nextest.toml
report=$tmp/report.xml
filter='test(=pass_case) && name ~ "quoted ; $HOME"'
set +e
BUCK2_NEXTEST_ARGV_LOG="$log" BUCK2_NEXTEST_PROFILE_CAPTURE="$capture" \
    "$root/adapter.sh" buck-artifact --build-mode --artifact "$artifact" --manifest "$manifest" --validator "$validator" --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" --runtime-resource "$root/runtime/buck2_artifact_runtime.txt" --source-denial "$root/tools/cargo_source_denial.sh" --action-metadata-parser "$root/tools/nextest_buck_artifact_action_metadata.py" --cargo-command "$root/tools/cargo_source_denial.sh" --python-command "$python_launcher" --cargo-nextest-command "$recorder" nextest --junit-report "$report" --profile custom-ci --filter "$filter" --no-tests warn --report-skipped ignored --timeout-seconds 7 >"$tmp/out" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] || { cat "$tmp/out" >&2; exit 1; }
[ -s "$report" ]
python3 - "$log" "$capture" "$report" "$filter" <<'PY'
import json
import sys
from pathlib import Path
log, capture, report, expected_filter = sys.argv[1:]
records = [json.loads(line) for line in Path(log).read_text().splitlines()]
run = next(record for record in records if "run" in record and "--filterset" in record)
assert run[run.index("--profile") + 1] == "custom-ci"
assert run[run.index("--filterset") + 1] == expected_filter
assert run[run.index("--no-tests") + 1] == "warn"
text = Path(capture).read_text()
assert '[profile.custom-ci]' in text
assert 'slow-timeout = { period = "7s", terminate-after = 1, grace-period = "0s" }' in text
assert '[profile.custom-ci.junit]' in text
assert 'report-skipped = "ignored"' in text
assert 'name="pass_case"' in Path(report).read_text()
PY
[ "$(grep -c 'cleanup=once' "$tmp/out")" -eq 1 ]
private_root=$(sed -n 's/.*cleanup=once root=//p' "$tmp/out")
[ -n "$private_root" ] && [ ! -e "$private_root" ]
printf '%s\n' 'configured adapter contract: passed'
