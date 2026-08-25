#!/bin/sh
set -eu

project=${BUCK_PROJECT_ROOT:-$(pwd -P)}
buck=${BUCK2:-buck2}
expected_target='root//:nextest_buck_artifact_junit_expected_failure'
consumer_target='root//:nextest_buck_artifact_junit_expected_failure_consumer'
category='nextest_buck_artifact_junit'
run_root=$(mktemp -d "${TMPDIR:-/tmp}/nextest-buck-junit-failure.XXXXXX")
first_isolation="nextest-buck-junit-failure-$$"
consumer_isolation="nextest-buck-junit-consumer-$$"
first_tmp="$run_root/first-tmp"
consumer_tmp="$run_root/consumer-tmp"
mkdir -p "$first_tmp" "$consumer_tmp"
first_event_log="$run_root/first-event-log.json-lines"
first_build_report="$run_root/first-build-report.json"
consumer_event_log="$run_root/consumer-event-log.json-lines"
consumer_build_report="$run_root/consumer-build-report.json"
first_output="$run_root/first-build.out"
rerun_output="$run_root/producer-rerun.out"
consumer_output="$run_root/consumer-build.out"
trap 'rm -rf "$run_root"' EXIT

before_reports="$run_root/before-reports"
after_reports="$run_root/after-reports"
find "$project" -maxdepth 1 -type f -name 'junit.xml' -print | sort >"$before_reports"

set +e
TMPDIR="$first_tmp" "$buck" --isolation-dir "$first_isolation" build //:nextest_buck_artifact_junit_expected_failure --event-log "$first_event_log" --build-report "$first_build_report" --show-full-output >"$first_output" 2>&1
first_status=$?
set -e
[ "$first_status" -ne 0 ] || { cat "$first_output"; printf '%s\n' 'expected failing declared-output build to fail' >&2; exit 1; }

what_failed="$run_root/what-failed.out"
if ! TMPDIR="$first_tmp" "$buck" --isolation-dir "$first_isolation" log what-failed --filter-category '^nextest_buck_artifact_junit$' "$first_event_log" >"$what_failed" 2>&1; then
    python3 - "$first_build_report" "$expected_target" "$category" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1]))
target, category = sys.argv[2:]
assert report["success"] is False, report
matches = [
    result for label, result in report["results"].items()
    if label == target or label.endswith(target.removeprefix("root"))
]
assert len(matches) == 1, (target, list(report["results"]))
result = matches[0]
assert result["success"] == "FAIL", result
for configured in result["configured"].values():
    for error in configured.get("errors", []):
        action_error = error.get("action_error", {})
        if (
            action_error.get("key", {}).get("owner", "").startswith(target)
            and action_error.get("name", {}).get("category") == category
        ):
            raise SystemExit(0)
raise AssertionError(result)
PY
else
    grep -F "$expected_target" "$what_failed" >/dev/null
    grep -F "$category" "$what_failed" >/dev/null
    grep -F 'test(=fail_case)' "$what_failed" >/dev/null
fi

# The Rust runner owns a private child below Buck's action scratch path and
# removes it after the process group is quiescent.  Assert that behavior by
# outcome, not by the retired shell cleanup log or private-directory spelling.
if find "$project/buck-out" -type d -name 'buck2-nextest-buck-artifact.*' -print -quit 2>/dev/null | grep -q .; then
    find "$project/buck-out" -type d -name 'buck2-nextest-buck-artifact.*' -print >&2
    cat "$first_output" >&2
    printf '%s\n' 'adapter scratch child was retained after failed action' >&2
    exit 1
fi

find "$project" -maxdepth 1 -type f -name 'junit.xml' -print | sort >"$after_reports"
cmp -s "$before_reports" "$after_reports"

set +e
TMPDIR="$first_tmp" "$buck" --isolation-dir "$first_isolation" build //:nextest_buck_artifact_junit_expected_failure --show-full-output >"$rerun_output" 2>&1
rerun_status=$?
set -e
[ "$rerun_status" -ne 0 ] || { cat "$rerun_output"; printf '%s\n' 'expected producer rerun to remain failed' >&2; exit 1; }

set +e
TMPDIR="$consumer_tmp" "$buck" --isolation-dir "$consumer_isolation" build //:nextest_buck_artifact_junit_expected_failure_consumer --event-log "$consumer_event_log" --build-report "$consumer_build_report" --show-full-output >"$consumer_output" 2>&1
consumer_status=$?
set -e
[ "$consumer_status" -ne 0 ] || { cat "$consumer_output"; printf '%s\n' 'expected failed producer to prevent consumer success' >&2; exit 1; }

python3 - "$consumer_build_report" "$consumer_target" "$expected_target" "$category" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1]))
consumer, producer, category = sys.argv[2:]
assert report["success"] is False, report
matches = [
    result for label, result in report["results"].items()
    if label == consumer or label.endswith(consumer.removeprefix("root"))
]
assert len(matches) == 1, (consumer, list(report["results"]))
result = matches[0]
assert result["success"] == "FAIL", result
for configured in result["configured"].values():
    for error in configured.get("errors", []):
        action_error = error.get("action_error", {})
        owner = action_error.get("key", {}).get("owner", "")
        if owner.startswith(producer) and action_error.get("name", {}).get("category") == category:
            raise SystemExit(0)
raise AssertionError(result)
PY

printf '%s\n' 'nextest declared JUnit failure semantics: passed'
