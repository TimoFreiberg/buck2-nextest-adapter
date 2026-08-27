#!/bin/sh
set -eu

project=${BUCK_PROJECT_ROOT:-$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)}
buck=${BUCK2:-buck2}
case "$(uname -s)" in
    Darwin|Linux) ;;
    *) printf '%s\n' 'real nextest production check: unsupported host OS' >&2; exit 2 ;;
esac
"$buck" test --help 2>&1 | grep -F -- '--event-log' >/dev/null || { printf '%s\n' 'real nextest production check: missing Buck event-log capability' >&2; exit 2; }
"$buck" build --help 2>&1 | grep -F -- '--show-output' >/dev/null || { printf '%s\n' 'real nextest production check: missing Buck show-output capability' >&2; exit 2; }
"$buck" log what-ran --help 2>&1 | grep -F -- '--filter-category' >/dev/null || { printf '%s\n' 'real nextest production check: missing what-ran category filter' >&2; exit 2; }

executor=$($buck build --show-output //:nextest_v2_executor | tail -1 | cut -d' ' -f2)
case "$executor" in /*) ;; *) executor="$project/$executor" ;; esac
executor=$(CDPATH= cd -- "$(dirname "$executor")" && pwd -P)/$(basename "$executor")

case "$(uname -s):$(uname -m)" in
    Darwin:x86_64|Darwin:arm64) version_label=toolchains//:nextest-real-macos-universal ;;
    Linux:x86_64|Linux:amd64) version_label=toolchains//:nextest-real-linux-x86_64 ;;
    Linux:aarch64|Linux:arm64) version_label=toolchains//:nextest-real-linux-aarch64 ;;
    *) printf '%s\n' 'real nextest production check: unsupported host architecture' >&2; exit 2 ;;
esac
version_tool=$($buck build --show-output "$version_label" 2>/dev/null | tail -1 | cut -d' ' -f2)
case "$version_tool" in /*) ;; *) version_tool="$project/$version_tool" ;; esac
case "$(uname -s)" in
    Darwin) temp_root=/private/tmp ;;
    Linux) temp_root=/tmp ;;
    *) printf '%s\n' 'real nextest production check: unsupported host OS' >&2; exit 2 ;;
esac
version_home=$(mktemp -d "$temp_root/buck2-nextest-version-home.XXXXXX")
trap 'rm -rf "$version_home" ${run_root:-}' EXIT HUP INT TERM
version=$(env -i HOME="$version_home" TMPDIR="$temp_root" PATH= "$version_tool" nextest --version)
printf '%s\n' "$version" | grep -F 'cargo-nextest 0.9.143 (' >/dev/null
printf '%s\n' "$version" | grep -F 'release: 0.9.143' >/dev/null

run_once() {
    name=$1
    root=$(mktemp -d "$temp_root/buck2-nextest-real.${name}.XXXXXX")
    root=$(CDPATH= cd -- "$root" && pwd -P)
    run_root=$root
    mkdir -p "$root/private/junit"
    isolation="nextest-real-${name}-$$"
    events="$root/events.json-lines"
    events=$(CDPATH= cd -- "$(dirname "$events")" && pwd -P)/$(basename "$events")
    set +e
    "$buck" --isolation-dir "$isolation" test --config "test.v2_test_executor=$executor" --event-log "$events" \
        --test-executor-stdout=- --test-executor-stderr=- \
        //:nextest_buck_test_generic_multi_binary -- --junit-dir "$root/private/junit" >"$root/output" 2>&1
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then cat "$root/output" >&2; printf 'real nextest production check: retained diagnostics at %s\n' "$root" >&2; run_root=; exit "$status"; fi
    report_count=$(find "$root/private/junit" -maxdepth 1 -type f -name '*.xml' | wc -l | tr -d ' ')
    if [ "$report_count" -ne 1 ]; then cat "$root/output" >&2; printf 'real nextest production check: retained diagnostics at %s\n' "$root" >&2; run_root=; exit 1; fi
    report=$(find "$root/private/junit" -maxdepth 1 -type f -name '*.xml' -print -quit)
    python3 - "$report" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = list(root.iter("testcase"))
assert len(cases) == 3, [case.attrib for case in cases]
assert all(case.attrib.get("name") == "pass_case" for case in cases)
classes = {case.attrib.get("classname", "") for case in cases}
assert any("package=demo-package" in value for value in classes) or any("p=demo-package" in value for value in classes)
assert any("other-demo-package" in value for value in classes)
PY
    if "$buck" log what-ran --format json --emit-cache-queries "$events" >"$root/what-ran" 2>"$root/what-ran.err"; then
        python3 - "$root/what-ran" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
matching = [row for row in rows if row.get("identity") == "nextest_buck_test_generic_multi_binary"]
assert len(matching) == 1, rows
assert matching[0].get("reason") == "test.run", matching[0]
assert matching[0].get("reproducer", {}).get("executor") == "Local", matching[0]
assert isinstance(matching[0].get("reproducer", {}).get("details", {}).get("command"), list), matching[0]
PY
    else
        printf '%s\n' 'real nextest production check: Buck event log is not parseable by what-ran' >&2
        cat "$root/what-ran.err" >&2
        exit 2
    fi
    rm -rf "$root"
    run_root=
}

run_once first
run_once second

run_bounded_case() {
    name=$1
    target=$2
    expected_status=$3
    root=$(mktemp -d "$temp_root/buck2-nextest-bounded.${name}.XXXXXX")
    root=$(CDPATH= cd -- "$root" && pwd -P)
    run_root=$root
    mkdir -p "$root/private/junit"
    set +e
    "$buck" --isolation-dir "nextest-bounded-${name}-$$" test --config "test.v2_test_executor=$executor" \
        "$target" -- --junit-dir "$root/private/junit" >"$root/output" 2>&1
    status=$?
    set -e
    if [ "$expected_status" = pass ]; then
        [ "$status" -eq 0 ] || { cat "$root/output" >&2; exit "$status"; }
    else
        [ "$status" -ne 0 ] || { cat "$root/output" >&2; exit 1; }
    fi
    report_count=$(find "$root/private/junit" -maxdepth 1 -type f -name '*.xml' | wc -l | tr -d ' ')
    case "$name" in
        ignored) [ "$report_count" -eq 1 ] || { cat "$root/output" >&2; exit 1; } ;;
        no-tests) [ "$report_count" -eq 1 ] || { cat "$root/output" >&2; exit 1; } ;;
        failure|timeout) [ "$report_count" -eq 1 ] || { cat "$root/output" >&2; exit 1; } ;;
        *) exit 1 ;;
    esac
    rm -rf "$root"
    run_root=
}

run_bounded_case failure //:nextest_buck_test_failure fail
run_bounded_case ignored //:nextest_buck_test_ignored pass
run_bounded_case no-tests //:nextest_buck_test_no_tests fail
run_bounded_case timeout //:nextest_buck_test_timeout fail
printf '%s\n' 'buck2 nextest real declared toolchain: passed'
