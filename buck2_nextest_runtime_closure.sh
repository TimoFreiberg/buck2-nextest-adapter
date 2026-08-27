#!/bin/sh
# Production schema-v2 runtime-closure check.
set -eu

project=${BUCK_PROJECT_ROOT:-$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)}
buck=${BUCK2:-buck2}
case "$(uname -s)" in
    Darwin) temp_root=/private/tmp ;;
    Linux) temp_root=/tmp ;;
    *) printf '%s\n' 'runtime closure: unsupported host OS' >&2; exit 2 ;;
esac
case "$(uname -s):$(uname -m)" in
    Darwin:x86_64|Darwin:arm64|Linux:x86_64|Linux:amd64|Linux:aarch64|Linux:arm64) ;;
    *) printf '%s\n' 'runtime closure: unsupported host architecture' >&2; exit 2 ;;
esac
"$buck" test --help 2>&1 | grep -F -- '--event-log' >/dev/null || { printf '%s\n' 'runtime closure: missing Buck event-log capability' >&2; exit 2; }
"$buck" log what-ran --help 2>&1 | grep -F -- '--filter-category' >/dev/null || { printf '%s\n' 'runtime closure: missing what-ran capability' >&2; exit 2; }

executor=$($buck build --show-output //:nextest_v2_executor | tail -1 | cut -d' ' -f2)
case "$executor" in /*) ;; *) executor="$project/$executor" ;; esac
executor=$(CDPATH= cd -- "$(dirname "$executor")" && pwd -P)/$(basename "$executor")
isolation="nextest-runtime-$$"

checksum() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'
    fi
}

run_case() {
    name=$1
    target=$2
    executable_target=$3
    expected=$4
    identity=$5
    root=$(mktemp -d "$temp_root/buck2-nextest-runtime.${name}.XXXXXX")
    root=$(CDPATH= cd -- "$root" && pwd -P)
    caller="$root/caller"
    junit="$caller/junit"
    observation="$root/observation"
    events="$root/events.json-lines"
    output="$root/output"
    mkdir -p "$junit" "$observation"
    cleanup() {
        status=$?
        if [ "$status" -ne 0 ]; then
            printf 'runtime closure: retained diagnostics at %s\n' "$root" >&2
            cat "$output" >&2 2>/dev/null || true
        else
            rm -rf "$root"
        fi
        exit "$status"
    }
    trap cleanup EXIT HUP INT TERM

    build_output=$($buck --isolation-dir "$isolation" build --no-remote-cache --show-output "$executable_target" 2>&1)
    executable=$(printf '%s\n' "$build_output" | awk '/^root\/\/.*[[:space:]][^[:space:]]+$/ { value=$NF } END { if (value == "") exit 1; print value }') || {
        printf '%s\n' "$build_output" >&2
        exit 1
    }
    case "$executable" in
        /*) ;;
        *) executable="$project/$executable" ;;
    esac
    executable=$(CDPATH= cd -- "$(dirname "$executable")" && pwd -P)/$(basename "$executable")
    database="${executable}.resources.json"
    [ -f "$executable" ] && [ ! -L "$executable" ] && [ -x "$executable" ]
    before_dir="$root/before-dir"
    after_dir="$root/after-dir"
    (CDPATH= cd -- "$(dirname "$executable")" && find . -mindepth 1 -maxdepth 1 -print | sort) >"$before_dir" || {
        printf '%s\n' "could not inspect executable directory: $(dirname "$executable")" >&2
        exit 1
    }
    executable_digest=$(checksum "$executable")
    database_digest=
    resource_digest=
    resource=
    if [ "$name" = positive ]; then
        [ -f "$database" ] && [ ! -L "$database" ]
        database_digest=$(checksum "$database")
        resource=$(python3 - "$database" "$executable" <<'PY'
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
key = "nextest-generated-rust-runtime-resource.txt"
relative = value.get(key)
if not isinstance(relative, str):
    raise SystemExit(f"missing resource key {key}")
print((pathlib.Path(sys.argv[2]).parent / relative).resolve())
PY
)
        [ -f "$resource" ] && [ ! -L "$resource" ]
        resource_digest=$(checksum "$resource")
    else
        [ ! -e "$database" ]
    fi

    set +e
    "$buck" --isolation-dir "$isolation" test --no-remote-cache \
        --config "test.v2_test_executor=$executor" \
        --config "nextest_test.observation_dir=$observation" \
        --config "nextest_test.nonce=${name}-$$" \
        --event-log "$events" --test-executor-stdout=- --test-executor-stderr=- \
        "$target" -- --junit-dir "$junit" >"$output" 2>&1
    status=$?
    set -e
    case "$expected" in
        pass) [ "$status" -eq 0 ] || { cat "$output" >&2; exit 1; } ;;
        fail) [ "$status" -ne 0 ] || { cat "$output" >&2; exit 1; } ;;
    esac
    case "$name" in
        positive) grep -F 'Tests finished:' "$output" >/dev/null; ! grep -F 'Infra Failure' "$output" >/dev/null ;;
        negative) grep -F 'buck2-nextest runtime closure missing generated resource' "$output" >/dev/null; ! grep -F 'Infra Failure' "$output" >/dev/null ;;
    esac
    [ -s "$events" ]
    "$buck" log what-ran --format json --no-remote "$events" >"$root/what-ran" 2>"$root/what-ran.err"
    python3 - "$root/what-ran" "$identity" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
matching = [row for row in rows if row.get("reason") == "test.run" and row.get("identity") == sys.argv[2]]
assert len(matching) == 1, [row.get("identity") for row in rows if row.get("reason") == "test.run"]
command = matching[0].get("reproducer", {}).get("details", {}).get("command")
assert isinstance(command, list), matching[0]
command = [str(value) for value in command]
assert command.count("--declared-input") == 1, command
assert any("runtime_resource_" in value for value in command), command
assert not any(value in " ".join(command).lower() for value in ("staging", "packaging", "runtime-destination", "runtime_destination")), command
PY

    (CDPATH= cd -- "$(dirname "$executable")" && find . -mindepth 1 -maxdepth 1 -print | sort) >"$after_dir"
    cmp "$before_dir" "$after_dir"
    [ "$(checksum "$executable")" = "$executable_digest" ]
    [ ! -e "${executable}.tmp" ]
    [ -f "$observation/runtime-closure-observation.txt" ] || [ "$name" = negative ]
    if [ "$name" = positive ]; then
        [ "$(checksum "$database")" = "$database_digest" ]
        [ "$(checksum "$resource")" = "$resource_digest" ]
        [ -s "$observation/runtime-closure-observation.txt" ]
        observed=$(sed -n 's/^executable=//p' "$observation/runtime-closure-observation.txt")
        [ "$observed" = "$executable" ]
        observed_database=$(sed -n 's/^database=//p' "$observation/runtime-closure-observation.txt")
        observed_resource=$(sed -n 's/^resource=//p' "$observation/runtime-closure-observation.txt")
        [ "$observed_database" = "$database" ]
        [ "$observed_resource" = "$resource" ]
    fi

    report_count=$(find "$junit" -mindepth 1 -maxdepth 1 -type f -name '*.xml' | wc -l | tr -d ' ')
    [ "$report_count" -eq 1 ]
    report=$(find "$junit" -mindepth 1 -maxdepth 1 -type f -name '*.xml' -print -quit)
    python3 - "$report" "$name" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = list(root.iter("testcase"))
assert len(cases) == 1, [case.attrib for case in cases]
assert cases[0].attrib.get("name") == "provider_runtime_resource_case"
if sys.argv[2] == "positive":
    assert cases[0].find("failure") is None
else:
    failure = cases[0].find("failure")
    assert failure is not None
    assert "buck2-nextest runtime closure missing generated resource" in "".join(failure.itertext())
PY

    python3 - "$root/what-ran" "$identity" "$name" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
matching = [row for row in rows if row.get("identity") == sys.argv[2] and row.get("reason") == "test.run"]
assert len(matching) == 1, [row.get("identity") for row in rows if row.get("reason") == "test.run"]
command = matching[0].get("reproducer", {}).get("details", {}).get("command")
assert isinstance(command, list), matching[0]
command = [str(value) for value in command]
assert any("cargo-nextest" in value for value in command), command
assert not any("nextest_buck_artifact" in value for value in command), command
assert "--declared-input" in command, command
assert any("runtime_resource_positive_executable" in value or "runtime_resource_negative_executable" in value for value in command), command
if sys.argv[3] == "positive":
    assert "provider-runtime" not in "".join(command), command
PY

    trap - EXIT HUP INT TERM
    rm -rf "$root"
    printf 'runtime closure: %s passed\n' "$name"
}

run_case positive //:nextest_buck_test_runtime_closure_positive //:nextest_buck_test_binary_runtime_positive pass nextest_buck_test_runtime_closure_positive
run_case negative //:nextest_buck_test_runtime_closure_negative //:nextest_buck_test_binary_runtime_negative fail nextest_buck_test_runtime_closure_negative
printf '%s\n' 'buck2 nextest runtime closure: passed'
