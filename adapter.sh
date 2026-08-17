#!/bin/sh
set -u

private_root=
cleanup_done=false
child_pid=
child_pgid=
state=PRE_DISPATCH
final_status=2
pending_signal=

usage() {
    printf '%s\n' 'usage: adapter.sh buck-artifact --artifact PATH --manifest PATH --validator PATH --cargo-baseline PATH --binary-baseline PATH --tests-baseline PATH --junit-report PATH [--scenario pass|fail|ignored|filtered|no-tests]' >&2
}

cleanup_and_exit() {
    status=$1
    state=FINALIZING
    trap - HUP INT TERM EXIT
    if [ "$cleanup_done" = false ]; then
        cleanup_done=true
        if [ -n "$child_pgid" ] && kill -0 "$child_pgid" 2>/dev/null; then
            kill -TERM -- "-$child_pgid" 2>/dev/null || true
            [ -n "$child_pid" ] && wait "$child_pid" 2>/dev/null || true
        elif [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
            kill -TERM "$child_pid" 2>/dev/null || true
            wait "$child_pid" 2>/dev/null || true
        fi
        if [ -n "$private_root" ] && [ -d "$private_root" ]; then
            rm -rf "$private_root"
            printf 'buck2-nextest-adapter: cleanup=once root=%s\n' "$private_root"
        fi
    fi
    exit "$status"
}

fail() {
    printf 'buck2-nextest-adapter: error: %s\n' "$1" >&2
    usage
    cleanup_and_exit 2
}

handle_signal() {
    signal=$1
    [ -n "$pending_signal" ] || pending_signal=$signal
    if [ "$state" = RUNNING ]; then
        if [ -n "$child_pgid" ]; then
            kill -TERM -- "-$child_pgid" 2>/dev/null || true
        elif [ -n "$child_pid" ]; then
            kill -TERM "$child_pid" 2>/dev/null || true
        fi
    fi
}
trap 'handle_signal HUP' HUP
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM
trap 'cleanup_and_exit "$final_status"' EXIT

resource_root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-${BUCK_PROJECT_ROOT:-.}}
invocation_cwd=$(pwd -P) || fail 'could not resolve invocation cwd'
mode=
scenario=pass
artifact=${BUCK2_NEXTEST_ARTIFACT:-}
manifest_input=${BUCK2_NEXTEST_MANIFEST:-}
validator=${BUCK2_NEXTEST_VALIDATOR:-}
baseline_dir=${BUCK2_NEXTEST_BASELINE:-}
baseline_cargo=${BUCK2_NEXTEST_CARGO_BASELINE:-}
baseline_binaries=${BUCK2_NEXTEST_BINARY_BASELINE:-}
baseline_tests=${BUCK2_NEXTEST_TESTS_BASELINE:-}
junit_report=

while [ "$#" -gt 0 ]; do
    case "$1" in
        buck-artifact)
            [ -z "$mode" ] || fail 'buck-artifact specified more than once'
            mode=buck-artifact
            shift
            ;;
        --artifact)
            [ "$#" -ge 2 ] || fail '--artifact requires a value'
            [ -z "$artifact" ] || fail 'artifact specified more than once'
            artifact=$2
            shift 2
            ;;
        --manifest)
            [ "$#" -ge 2 ] || fail '--manifest requires a value'
            [ -z "$manifest_input" ] || fail 'manifest specified more than once'
            manifest_input=$2
            shift 2
            ;;
        --validator)
            [ "$#" -ge 2 ] || fail '--validator requires a value'
            [ -z "$validator" ] || fail 'validator specified more than once'
            validator=$2
            shift 2
            ;;
        --baseline)
            [ "$#" -ge 2 ] || fail '--baseline requires a value'
            [ -z "$baseline_dir" ] || fail 'baseline specified more than once'
            baseline_dir=$2
            shift 2
            ;;
        --cargo-baseline)
            [ "$#" -ge 2 ] || fail '--cargo-baseline requires a value'
            [ -z "$baseline_cargo" ] || fail 'cargo baseline specified more than once'
            baseline_cargo=$2
            shift 2
            ;;
        --binary-baseline)
            [ "$#" -ge 2 ] || fail '--binary-baseline requires a value'
            [ -z "$baseline_binaries" ] || fail 'binary baseline specified more than once'
            baseline_binaries=$2
            shift 2
            ;;
        --tests-baseline)
            [ "$#" -ge 2 ] || fail '--tests-baseline requires a value'
            [ -z "$baseline_tests" ] || fail 'tests baseline specified more than once'
            baseline_tests=$2
            shift 2
            ;;
        --junit-report)
            [ "$#" -ge 2 ] || fail '--junit-report requires a value'
            [ -z "$junit_report" ] || fail 'JUnit report specified more than once'
            junit_report=$2
            shift 2
            ;;
        --scenario)
            [ "$#" -ge 2 ] || fail '--scenario requires a value'
            scenario=$2
            shift 2
            ;;
        -h|--help)
            usage
            cleanup_and_exit 0
            ;;
        *) fail "unknown option: $1" ;;
    esac
done

[ "$mode" = buck-artifact ] || fail 'the required mode is buck-artifact'
case "$scenario" in
    pass|filtered) filterset='test(=pass_case)'; no_tests= ;;
    fail) filterset='test(=fail_case)'; no_tests= ;;
    ignored) filterset='test(=ignored_case)'; no_tests='--no-tests pass' ;;
    no-tests) filterset='test(=does_not_exist)'; no_tests='--no-tests fail' ;;
    *) fail "invalid scenario: $scenario" ;;
esac

[ -n "$artifact" ] || fail 'buck-artifact requires --artifact or BUCK2_NEXTEST_ARTIFACT'
[ -n "$manifest_input" ] || fail 'buck-artifact requires --manifest or BUCK2_NEXTEST_MANIFEST'
[ -n "$validator" ] || fail 'buck-artifact requires --validator or BUCK2_NEXTEST_VALIDATOR'
if [ -z "$baseline_cargo$baseline_binaries$baseline_tests" ] && [ -n "$baseline_dir" ]; then
    baseline_cargo=$baseline_dir/cargo-metadata.json
    baseline_binaries=$baseline_dir/binaries.json
    baseline_tests=$baseline_dir/tests.json
fi
[ -n "$baseline_cargo" ] && [ -n "$baseline_binaries" ] && [ -n "$baseline_tests" ] || fail 'buck-artifact requires all three baseline metadata inputs'
[ -n "$junit_report" ] || fail 'buck-artifact requires --junit-report PATH'
[ -x "$artifact" ] && [ -f "$artifact" ] && [ ! -L "$artifact" ] || fail "declared Buck artifact is not an executable regular file: $artifact"
[ -r "$manifest_input" ] && [ -f "$manifest_input" ] && [ ! -L "$manifest_input" ] || fail "manifest is not a readable regular file: $manifest_input"
if [ -f "$validator" ] && [ ! -L "$validator" ]; then
    validator_script=$validator
else
    validator_script=$validator/nextest_artifact.py
fi
[ -r "$validator_script" ] && [ -f "$validator_script" ] && [ ! -L "$validator_script" ] || fail "validator helper is not declared: $validator"
for input in "$baseline_cargo" "$baseline_binaries" "$baseline_tests"; do
    [ -r "$input" ] && [ -f "$input" ] && [ ! -L "$input" ] || fail "baseline metadata is not a readable regular file: $input"
done
command -v cargo >/dev/null 2>&1 || fail 'cargo is not available on PATH'
command -v python3 >/dev/null 2>&1 || fail 'python3 is not available on PATH'

junit_report=$(python3 - "$invocation_cwd" "$junit_report" <<'PY'
import os
import stat
import sys
from pathlib import Path
cwd, supplied = sys.argv[1:]
if not supplied or "\0" in supplied:
    raise SystemExit("report destination must be a non-empty path")
destination = Path(supplied)
if not destination.is_absolute():
    destination = Path(cwd) / destination
destination = Path(os.path.normpath(destination))
parent = destination.parent
parts = parent.parts
current = Path(parts[0]) if parts and parts[0] == os.sep else Path()
for part in parts[1:] if current == Path(os.sep) else parts:
    current = current / part
    try:
        mode = os.lstat(current).st_mode
    except FileNotFoundError:
        raise SystemExit(f"report parent does not exist: {current}")
    if stat.S_ISLNK(mode):
        raise SystemExit(f"report parent must not traverse a symlink: {current}")
    if not stat.S_ISDIR(mode):
        raise SystemExit(f"report parent component is not a directory: {current}")
try:
    mode = os.lstat(destination).st_mode
except FileNotFoundError:
    pass
else:
    if stat.S_ISLNK(mode):
        raise SystemExit("report destination must not be a symlink")
    if not stat.S_ISREG(mode):
        raise SystemExit("report destination must be a regular file when it exists")
print(destination)
PY
) || fail 'invalid JUnit report destination'

if command -v setsid >/dev/null 2>&1; then
    launcher=setsid
else
    launcher=
fi
if [ "${BUCK2_NEXTEST_REQUIRE_PROCESS_GROUP:-0}" = 1 ] && [ -z "$launcher" ]; then
    fail 'setsid is required for signal-cleanup scenarios but is unavailable'
fi

private_root=$(mktemp -d "${TMPDIR:-/tmp}/buck2-nextest-buck-artifact.XXXXXX") || fail 'could not create private root'
mkdir -p "$private_root/workspace/src" "$private_root/workspace/.config" "$private_root/target/debug/deps" "$private_root/cargo-home" || fail 'could not create private staging directories'
cp "$manifest_input" "$private_root/manifest.json" || fail 'could not stage manifest'
cp "$validator_script" "$private_root/nextest_artifact.py" || fail 'could not stage validator'
cp "$baseline_cargo" "$private_root/baseline-cargo.json" || fail 'could not stage Cargo baseline'
cp "$baseline_binaries" "$private_root/baseline-binaries.json" || fail 'could not stage binary baseline'
cp "$baseline_tests" "$private_root/baseline-tests.json" || fail 'could not stage tests baseline'

source_denial=${BUCK2_NEXTEST_SOURCE_DENIAL:-}
if [ -z "$source_denial" ]; then
    source_denial="$resource_root/tools/cargo_source_denial.sh"
    [ -r "$source_denial" ] || source_denial="$resource_root/cargo_source_denial.sh"
fi
[ -r "$source_denial" ] && [ -f "$source_denial" ] && [ ! -L "$source_denial" ] || fail "source-denial helper is not declared: $source_denial"
cp "$source_denial" "$private_root/cargo" || fail 'could not stage source-denial cargo wrapper'
cp "$source_denial" "$private_root/rustc" || fail 'could not stage source-denial rustc wrapper'
chmod +x "$private_root/cargo" "$private_root/rustc" || fail 'could not make source-denial wrappers executable'

python3 "$private_root/nextest_artifact.py" validate-manifest --manifest "$private_root/manifest.json" --root "$private_root" --allow-missing || fail 'manifest validation failed'
python3 "$private_root/nextest_artifact.py" stage-runtime --manifest "$private_root/manifest.json" --root "$private_root" --resources "$resource_root" || fail 'runtime staging failed'
executable_rel=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["paths"]["executable"])' "$private_root/manifest.json") || fail 'could not read executable path'
working_rel=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["paths"]["working_directory"])' "$private_root/manifest.json") || fail 'could not read working-directory path'
executable_stage="$private_root/$executable_rel"
working_stage="$private_root/$working_rel"
mkdir -p "$(dirname "$executable_stage")" "$working_stage" || fail 'could not create declared staging paths'
cp "$artifact" "$executable_stage" || fail 'could not stage declared artifact'
chmod +x "$executable_stage" || fail 'could not make staged artifact executable'
python3 "$private_root/nextest_artifact.py" validate-manifest --manifest "$private_root/manifest.json" --root "$private_root" || fail 'staged manifest validation failed'
python3 "$private_root/nextest_artifact.py" synthesize --cargo-baseline "$private_root/baseline-cargo.json" --binary-baseline "$private_root/baseline-binaries.json" --tests-baseline "$private_root/baseline-tests.json" --target-dir "$private_root/target" --workspace "$private_root/workspace" --output-dir "$private_root/meta" --manifest "$private_root/manifest.json" --manifest-root "$private_root" || fail 'metadata synthesis failed'
cp "$executable_stage" "$private_root/target/debug/deps/buck2_nextest_rust_test" || fail 'could not install staged test executable'
chmod +x "$private_root/target/debug/deps/buck2_nextest_rust_test" || fail 'could not make installed test executable executable'
eval "$(python3 "$private_root/nextest_artifact.py" emit-environment --manifest "$private_root/manifest.json" --root "$private_root")" || fail 'could not apply manifest environment'

printf '%s\n' '[package]' 'name = "buck2-nextest-buck-artifact"' 'version = "0.1.0"' 'edition = "2021"' >"$private_root/workspace/Cargo.toml" || fail 'could not write staged Cargo manifest'
if [ "$scenario" = ignored ]; then
    printf '%s\n' '[profile.ci.junit]' 'path = "junit.xml"' 'report-skipped = "ignored"' >"$private_root/workspace/.config/nextest.toml" || fail 'could not write nextest JUnit profile'
else
    printf '%s\n' '[profile.ci.junit]' 'path = "junit.xml"' >"$private_root/workspace/.config/nextest.toml" || fail 'could not write nextest JUnit profile'
fi

export CARGO_NET_OFFLINE=true
export CARGO_TARGET_DIR="$private_root/target"
export CARGO_MANIFEST_DIR="$private_root/workspace"
export CARGO_HOME="$private_root/cargo-home"
export BUCK2_NEXTEST_REAL_CARGO=$(command -v cargo)
export BUCK2_NEXTEST_DISPATCH_LOG=${BUCK2_NEXTEST_DISPATCH_LOG:-$private_root/dispatch.log}
export BUCK2_NEXTEST_PROBE_LOG=${BUCK2_NEXTEST_PROBE_LOG:-$private_root/probe.log}
export BUCK2_NEXTEST_NESTED_CARGO_LOG=${BUCK2_NEXTEST_NESTED_CARGO_LOG:-$private_root/nested-cargo.log}
export BUCK2_NEXTEST_COMPILER_LOG=${BUCK2_NEXTEST_COMPILER_LOG:-$private_root/compiler.log}
export BUCK2_NEXTEST_DISPATCH_ALLOWED=1
export PATH="$private_root:$PATH"
: >"$BUCK2_NEXTEST_DISPATCH_LOG" || fail 'could not initialize dispatch sentinel'
: >"$BUCK2_NEXTEST_PROBE_LOG" || fail 'could not initialize probe sentinel'
: >"$BUCK2_NEXTEST_NESTED_CARGO_LOG" || fail 'could not initialize nested-Cargo sentinel'
: >"$BUCK2_NEXTEST_COMPILER_LOG" || fail 'could not initialize compiler sentinel'

help_output=$(cargo nextest run --help 2>&1) || fail 'cargo nextest is not available'
for flag in --filterset --cargo-metadata --binaries-metadata --target-dir-remap --workspace-remap --build-dir-remap --success-output --failure-output --profile; do
    printf '%s\n' "$help_output" | grep -F -- "$flag" >/dev/null 2>&1 || fail "cargo nextest run does not expose $flag"
done
list_help=$(cargo nextest list --help 2>&1) || fail 'cargo nextest list is not available'
for flag in --cargo-metadata --binaries-metadata --target-dir-remap --workspace-remap --build-dir-remap; do
    printf '%s\n' "$list_help" | grep -F -- "$flag" >/dev/null 2>&1 || fail "cargo nextest list does not expose $flag"
done

digest_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}
buck_digest=$(digest_file "$artifact") || fail 'could not digest declared artifact'
staged_digest=$(digest_file "$executable_stage") || fail 'could not digest staged artifact'
[ "$buck_digest" = "$staged_digest" ] || fail 'declared and staged artifact digests differ'
printf 'buck2-nextest-adapter: mode=buck-artifact scenario=%s\n' "$scenario"
printf 'buck2-nextest-adapter: buck-output=%s digest=%s\n' "$artifact" "$buck_digest"
printf 'buck2-nextest-adapter: staged-executable=%s digest=%s\n' "$executable_stage" "$staged_digest"
printf 'buck2-nextest-adapter: manifest-root=%s metadata=%s\n' "$private_root" "$private_root/meta"
printf 'buck2-nextest-adapter: junit-report=%s\n' "$junit_report"

nextest_with_metadata() {
    if [ -n "$launcher" ]; then
        "$launcher" cargo nextest "$@" --cargo-metadata "$private_root/meta/cargo-metadata.json" --binaries-metadata "$private_root/meta/binaries-metadata.json" --target-dir-remap "$private_root/target" --build-dir-remap "$private_root/target" --workspace-remap "$private_root/workspace"
    else
        command cargo nextest "$@" --cargo-metadata "$private_root/meta/cargo-metadata.json" --binaries-metadata "$private_root/meta/binaries-metadata.json" --target-dir-remap "$private_root/target" --build-dir-remap "$private_root/target" --workspace-remap "$private_root/workspace"
    fi
}

cd "$private_root/workspace" || fail 'could not enter synthesized workspace'
printf 'buck2-nextest-adapter: exec cargo nextest list --message-format json (supplied metadata)\n'
nextest_with_metadata list --message-format json >"$private_root/list.json"
list_status=$?
if [ "$list_status" -ne 0 ]; then
    printf 'buck2-nextest-adapter: nextest list failed status=%s\n' "$list_status" >&2
    final_status=$list_status
    cleanup_and_exit "$final_status"
fi
[ -s "$BUCK2_NEXTEST_DISPATCH_LOG" ] || fail 'nextest dispatch sentinel did not record top-level cargo nextest'
[ ! -s "$BUCK2_NEXTEST_NESTED_CARGO_LOG" ] || fail 'nested Cargo operation was attempted'
[ ! -s "$BUCK2_NEXTEST_COMPILER_LOG" ] || fail 'compiler invocation was attempted'
grep -F 'buck2_nextest_rust_test' "$private_root/list.json" >/dev/null 2>&1 || fail 'synthetic binary was not listed'
grep -F 'pass_case' "$private_root/list.json" >/dev/null 2>&1 || fail 'pass_case was not listed'
grep -F 'fail_case' "$private_root/list.json" >/dev/null 2>&1 || fail 'fail_case was not listed'
grep -F 'ignored_case' "$private_root/list.json" >/dev/null 2>&1 || fail 'ignored_case was not listed'

printf 'buck2-nextest-adapter: exec cargo nextest run --profile ci --filterset %s (supplied metadata)\n' "$filterset"
output_mode=--success-output
[ "$scenario" = fail ] && output_mode=--failure-output
state=RUNNING
# shellcheck disable=SC2086
nextest_with_metadata run --profile ci --message-format human --filterset "$filterset" $no_tests "$output_mode" immediate-final &
child_pid=$!
[ -n "$launcher" ] && child_pgid=$child_pid
wait "$child_pid"
raw_status=$?
if [ -n "$pending_signal" ]; then
    while kill -0 "$child_pid" 2>/dev/null; do
        wait "$child_pid" 2>/dev/null || true
    done
fi
child_pid=
child_pgid=
state=CHILD_EXITED
internal_report="$private_root/workspace/target/nextest/ci/junit.xml"

if [ -n "${BUCK2_NEXTEST_EXPORT_FAULT_GATE:-}" ] && [ -n "${BUCK2_NEXTEST_EXPORT_FAULT_MARKER:-}" ]; then
    printf '%s\n%s\n' "$internal_report" "$raw_status" >"$BUCK2_NEXTEST_EXPORT_FAULT_MARKER" || true
    while [ -e "$BUCK2_NEXTEST_EXPORT_FAULT_GATE" ]; do
        sleep 1
    done
fi

state=EXPORTING
report_exists=false
[ -f "$internal_report" ] && [ ! -L "$internal_report" ] && report_exists=true
required=false
case "$raw_status" in
    0|100) required=true ;;
esac

export_error=
if [ "$report_exists" = true ]; then
    if ! python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$internal_report"
    then
        export_error='nextest JUnit report is not valid XML'
    else
        report_parent=$(dirname "$junit_report")
        report_base=$(basename "$junit_report")
        report_tmp=$(mktemp "$report_parent/.${report_base}.tmp.XXXXXX") || report_tmp=
        if [ -z "$report_tmp" ]; then
            export_error='could not create same-directory report temporary'
        elif ! chmod 600 "$report_tmp"; then
            export_error='could not restrict report temporary permissions'
            rm -f "$report_tmp"
        elif ! cp "$internal_report" "$report_tmp"; then
            export_error='could not copy nextest JUnit to report temporary'
            rm -f "$report_tmp"
        elif ! mv -f "$report_tmp" "$junit_report"; then
            export_error='could not atomically replace JUnit destination'
            rm -f "$report_tmp"
        fi
    fi
elif [ "$required" = true ]; then
    export_error='required nextest JUnit report is absent'
fi

if [ -n "$export_error" ]; then
    printf 'buck2-nextest-adapter: raw nextest status=%s; export error: %s\n' "$raw_status" "$export_error" >&2
    final_status=3
else
    final_status=$raw_status
fi
cleanup_and_exit "$final_status"
