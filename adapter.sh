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
    printf '%s\n' 'usage: adapter.sh buck-artifact --artifact PATH --manifest PATH --validator PATH --cargo-baseline PATH --binary-baseline PATH --tests-baseline PATH --junit-report PATH [--profile NAME] [--filter EXPRESSION] [--no-tests auto|pass|warn|fail] [--report-skipped default|ignored] [--timeout-seconds N]' >&2
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
build_mode=false
cargo_command=${BUCK2_NEXTEST_CARGO_COMMAND:-}
python_command=${BUCK2_NEXTEST_PYTHON_COMMAND:-python3}
cargo_nextest_command=${BUCK2_NEXTEST_CARGO_NEXTEST_COMMAND:-}
cargo_nextest_subcommand=${BUCK2_NEXTEST_CARGO_NEXTEST_SUBCOMMAND:-nextest}
runtime_resource=${BUCK2_NEXTEST_RUNTIME_RESOURCE:-}
source_denial_arg=${BUCK2_NEXTEST_SOURCE_DENIAL:-}
option_command_mode=false
real_cargo_command=
profile=ci
filterset='test(=pass_case)'
no_tests=auto
report_skipped=default
timeout_seconds=0
profile_set=false
filter_set=false
no_tests_set=false
report_skipped_set=false
timeout_seconds_set=false
artifact=${BUCK2_NEXTEST_ARTIFACT:-}
manifest_input=${BUCK2_NEXTEST_MANIFEST:-}
validator=${BUCK2_NEXTEST_VALIDATOR:-}
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
        --build-mode)
            [ "$build_mode" = false ] || fail 'build mode specified more than once'
            build_mode=true
            option_command_mode=true
            shift
            ;;
        --cargo-command)
            [ "$#" -ge 2 ] || fail '--cargo-command requires a value'
            [ -z "$cargo_command" ] || fail 'cargo command specified more than once'
            cargo_command=$2
            option_command_mode=true
            shift 2
            ;;
        --python-command)
            [ "$#" -ge 2 ] || fail '--python-command requires a value'
            [ "$python_command" = python3 ] || fail 'python command specified more than once'
            python_command=$2
            option_command_mode=true
            shift 2
            ;;
        --cargo-nextest-command)
            [ "$#" -ge 3 ] || fail '--cargo-nextest-command requires a command and subcommand'
            [ -z "$cargo_nextest_command" ] || fail 'cargo-nextest command specified more than once'
            cargo_nextest_command=$2
            cargo_nextest_subcommand=$3
            option_command_mode=true
            shift 3
            ;;
        --runtime-resource)
            [ "$#" -ge 2 ] || fail '--runtime-resource requires a value'
            [ -z "$runtime_resource" ] || fail 'runtime resource specified more than once'
            runtime_resource=$2
            option_command_mode=true
            shift 2
            ;;
        --source-denial)
            [ "$#" -ge 2 ] || fail '--source-denial requires a value'
            [ -z "$source_denial_arg" ] || fail 'source-denial specified more than once'
            source_denial_arg=$2
            option_command_mode=true
            shift 2
            ;;
        --profile)
            [ "$#" -ge 2 ] || fail '--profile requires a value'
            [ "$profile_set" = false ] || fail 'profile specified more than once'
            profile=$2
            profile_set=true
            shift 2
            ;;
        --filter)
            [ "$#" -ge 2 ] || fail '--filter requires a value'
            [ "$filter_set" = false ] || fail 'filter specified more than once'
            filterset=$2
            filter_set=true
            shift 2
            ;;
        --no-tests)
            [ "$#" -ge 2 ] || fail '--no-tests requires a value'
            [ "$no_tests_set" = false ] || fail 'no-tests specified more than once'
            no_tests=$2
            no_tests_set=true
            shift 2
            ;;
        --report-skipped)
            [ "$#" -ge 2 ] || fail '--report-skipped requires a value'
            [ "$report_skipped_set" = false ] || fail 'report-skipped specified more than once'
            report_skipped=$2
            report_skipped_set=true
            shift 2
            ;;
        --timeout-seconds)
            [ "$#" -ge 2 ] || fail '--timeout-seconds requires a value'
            [ "$timeout_seconds_set" = false ] || fail 'timeout-seconds specified more than once'
            timeout_seconds=$2
            timeout_seconds_set=true
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
config_error=$($python_command - "$profile" "$filterset" "$no_tests" "$report_skipped" "$timeout_seconds" <<'PY'
import re
import sys

profile, filterset, no_tests, report_skipped, timeout = sys.argv[1:]
if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", profile, flags=re.ASCII) is None:
    print("invalid profile: expected [A-Za-z0-9][A-Za-z0-9_-]*")
    raise SystemExit(1)
if not filterset:
    print("filter must be non-empty")
    raise SystemExit(1)
if no_tests not in {"auto", "pass", "warn", "fail"}:
    print("invalid no-tests value: expected auto|pass|warn|fail")
    raise SystemExit(1)
if report_skipped not in {"default", "ignored"}:
    print("invalid report-skipped value: expected default|ignored")
    raise SystemExit(1)
if not re.fullmatch(r"[0-9]+", timeout, flags=re.ASCII) or int(timeout) > 86400:
    print("invalid timeout-seconds value: expected an integer from 0 through 86400")
    raise SystemExit(1)
PY
) || fail "$config_error"

[ -n "$artifact" ] || fail 'buck-artifact requires --artifact or BUCK2_NEXTEST_ARTIFACT'
[ -n "$manifest_input" ] || fail 'buck-artifact requires --manifest or BUCK2_NEXTEST_MANIFEST'
[ -n "$validator" ] || fail 'buck-artifact requires --validator or BUCK2_NEXTEST_VALIDATOR'
[ -n "$baseline_cargo" ] && [ -n "$baseline_binaries" ] && [ -n "$baseline_tests" ] || fail 'buck-artifact requires all three baseline metadata inputs'
[ -n "$junit_report" ] || fail 'buck-artifact requires --junit-report PATH'
if [ "$build_mode" = true ]; then
    for variable in cargo_command python_command cargo_nextest_command runtime_resource source_denial_arg; do
        eval "value=\${$variable}"
        case "$value" in
            /*) ;;
            */*) eval "$variable=\$invocation_cwd/\$value" ;;
        esac
    done
    [ -n "$cargo_command" ] || fail 'build mode requires --cargo-command'
    [ -n "$cargo_nextest_command" ] || fail 'build mode requires --cargo-nextest-command'
    [ -n "$runtime_resource" ] || fail 'build mode requires --runtime-resource'
    [ -n "$source_denial_arg" ] || fail 'build mode requires --source-denial'
fi
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
if [ "$option_command_mode" = false ]; then
    command -v cargo >/dev/null 2>&1 || fail 'cargo is not available on PATH'
    command -v python3 >/dev/null 2>&1 || fail 'python3 is not available on PATH'
    real_cargo_command=$(command -v cargo)
fi

junit_report=$($python_command - "$invocation_cwd" "$junit_report" <<'PY'
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
    if stat.S_ISLNK(mode) and not (current == Path(os.sep) or current == Path('/var')):
        raise SystemExit(f"report parent must not traverse a symlink: {current}")
    if not stat.S_ISDIR(mode) and current != Path('/var'):
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

source_denial=$source_denial_arg
if [ -z "$source_denial" ]; then
    source_denial="$resource_root/tools/cargo_source_denial.sh"
    [ -r "$source_denial" ] || source_denial="$resource_root/cargo_source_denial.sh"
fi
[ -r "$source_denial" ] && [ -f "$source_denial" ] && [ ! -L "$source_denial" ] || fail "source-denial helper is not declared: $source_denial"
cp "$source_denial" "$private_root/cargo" || fail 'could not stage source-denial cargo wrapper'
cp "$source_denial" "$private_root/rustc" || fail 'could not stage source-denial rustc wrapper'
chmod +x "$private_root/cargo" "$private_root/rustc" || fail 'could not make source-denial wrappers executable'

$python_command "$private_root/nextest_artifact.py" validate-manifest --manifest "$private_root/manifest.json" --root "$private_root" --allow-missing || fail 'manifest validation failed'
if [ "$build_mode" = true ]; then
    resource_root=$private_root/resources
    mkdir -p "$private_root/resources/runtime"
    cp "$runtime_resource" "$private_root/resources/runtime/buck2_artifact_runtime.txt" || fail 'could not stage declared runtime resource'
fi
$python_command "$private_root/nextest_artifact.py" stage-runtime --manifest "$private_root/manifest.json" --root "$private_root" --resources "$resource_root" || fail 'runtime staging failed'
executable_rel=$($python_command -c 'import json,sys; print(json.load(open(sys.argv[1]))["paths"]["executable"])' "$private_root/manifest.json") || fail 'could not read executable path'
working_rel=$($python_command -c 'import json,sys; print(json.load(open(sys.argv[1]))["paths"]["working_directory"])' "$private_root/manifest.json") || fail 'could not read working-directory path'
executable_stage="$private_root/$executable_rel"
working_stage="$private_root/$working_rel"
mkdir -p "$(dirname "$executable_stage")" "$working_stage" || fail 'could not create declared staging paths'
cp "$artifact" "$executable_stage" || fail 'could not stage declared artifact'
chmod +x "$executable_stage" || fail 'could not make staged artifact executable'
$python_command "$private_root/nextest_artifact.py" validate-manifest --manifest "$private_root/manifest.json" --root "$private_root" || fail 'staged manifest validation failed'
$python_command "$private_root/nextest_artifact.py" synthesize --cargo-baseline "$private_root/baseline-cargo.json" --binary-baseline "$private_root/baseline-binaries.json" --tests-baseline "$private_root/baseline-tests.json" --target-dir "$private_root/target" --workspace "$private_root/workspace" --output-dir "$private_root/meta" --manifest "$private_root/manifest.json" --manifest-root "$private_root" || fail 'metadata synthesis failed'
cp "$executable_stage" "$private_root/target/debug/deps/buck2_nextest_rust_test" || fail 'could not install staged test executable'
chmod +x "$private_root/target/debug/deps/buck2_nextest_rust_test" || fail 'could not make installed test executable executable'
eval "$($python_command "$private_root/nextest_artifact.py" emit-environment --manifest "$private_root/manifest.json" --root "$private_root")" || fail 'could not apply manifest environment'

printf '%s\n' '[package]' 'name = "buck2-nextest-buck-artifact"' 'version = "0.1.0"' 'edition = "2021"' >"$private_root/workspace/Cargo.toml" || fail 'could not write staged Cargo manifest'
{
    if [ "$timeout_seconds" -gt 0 ]; then
        printf '%s\n' '[profile.'"$profile"']' 'slow-timeout = { period = "'"$timeout_seconds"'s", terminate-after = 1, grace-period = "0s" }'
    fi
    printf '%s\n' '[profile.'"$profile"'.junit]' 'path = "junit.xml"'
    if [ "$report_skipped" = ignored ]; then
        printf '%s\n' 'report-skipped = "ignored"'
    fi
} >"$private_root/workspace/.config/nextest.toml" || fail 'could not write nextest profile'
if [ -n "${BUCK2_NEXTEST_PROFILE_CAPTURE:-}" ]; then
    cp "$private_root/workspace/.config/nextest.toml" "$BUCK2_NEXTEST_PROFILE_CAPTURE" || fail 'could not capture nextest profile'
fi

export CARGO_NET_OFFLINE=true
export CARGO_TARGET_DIR="$private_root/target"
export CARGO_MANIFEST_DIR="$private_root/workspace"
export CARGO_HOME="$private_root/cargo-home"
if [ -n "$real_cargo_command" ]; then
    export BUCK2_NEXTEST_REAL_CARGO=$real_cargo_command
else
    export BUCK2_NEXTEST_REAL_CARGO=$cargo_command
fi
export BUCK2_NEXTEST_DISPATCH_LOG=${BUCK2_NEXTEST_DISPATCH_LOG:-$private_root/dispatch.log}
export BUCK2_NEXTEST_PROBE_LOG=${BUCK2_NEXTEST_PROBE_LOG:-$private_root/probe.log}
export BUCK2_NEXTEST_NESTED_CARGO_LOG=${BUCK2_NEXTEST_NESTED_CARGO_LOG:-$private_root/nested-cargo.log}
export BUCK2_NEXTEST_COMPILER_LOG=${BUCK2_NEXTEST_COMPILER_LOG:-$private_root/compiler.log}
for log_name in BUCK2_NEXTEST_DISPATCH_LOG BUCK2_NEXTEST_PROBE_LOG BUCK2_NEXTEST_NESTED_CARGO_LOG BUCK2_NEXTEST_COMPILER_LOG; do
    eval "log_value=\${$log_name}"
    case "$log_value" in
        /*) ;;
        *) log_value=$invocation_cwd/$log_value ;;
    esac
    eval "export $log_name=\$log_value"
done
export BUCK2_NEXTEST_DISPATCH_ALLOWED=1
if [ "$option_command_mode" = false ]; then
    export PATH="$private_root:$PATH"
fi
: >"$BUCK2_NEXTEST_DISPATCH_LOG" || fail 'could not initialize dispatch sentinel'
: >"$BUCK2_NEXTEST_PROBE_LOG" || fail 'could not initialize probe sentinel'
: >"$BUCK2_NEXTEST_NESTED_CARGO_LOG" || fail 'could not initialize nested-Cargo sentinel'
: >"$BUCK2_NEXTEST_COMPILER_LOG" || fail 'could not initialize compiler sentinel'

if [ "$build_mode" = true ]; then
    nextest_command="$cargo_nextest_command $cargo_nextest_subcommand"
else
    nextest_command=cargo
fi
if [ "$build_mode" = true ]; then
    help_output=$("$cargo_nextest_command" "$cargo_nextest_subcommand" run --help 2>&1) || fail 'cargo nextest is not available'
elif [ "$option_command_mode" = true ]; then
    help_output=$("$cargo_command" nextest run --help 2>&1) || fail 'cargo nextest is not available'
else
    help_output=$("$real_cargo_command" nextest run --help 2>&1) || fail 'cargo nextest is not available'
fi
for flag in --filterset --cargo-metadata --binaries-metadata --target-dir-remap --workspace-remap --build-dir-remap --success-output --failure-output --profile --no-tests; do
    printf '%s\n' "$help_output" | grep -F -- "$flag" >/dev/null 2>&1 || fail "cargo nextest run does not expose $flag"
done
if [ "$build_mode" = true ]; then
    list_help=$("$cargo_nextest_command" "$cargo_nextest_subcommand" list --help 2>&1) || fail 'cargo nextest is not available'
elif [ "$option_command_mode" = true ]; then
    list_help=$("$cargo_command" nextest list --help 2>&1) || fail 'cargo nextest is not available'
else
    list_help=$("$real_cargo_command" nextest list --help 2>&1) || fail 'cargo nextest is not available'
fi
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
printf 'buck2-nextest-adapter: mode=buck-artifact profile=%s filter=%s no-tests=%s report-skipped=%s timeout-seconds=%s\n' "$profile" "$filterset" "$no_tests" "$report_skipped" "$timeout_seconds"
printf 'buck2-nextest-adapter: buck-output=%s digest=%s\n' "$artifact" "$buck_digest"
printf 'buck2-nextest-adapter: staged-executable=%s digest=%s\n' "$executable_stage" "$staged_digest"
printf 'buck2-nextest-adapter: manifest-root=%s metadata=%s\n' "$private_root" "$private_root/meta"
printf 'buck2-nextest-adapter: junit-report=%s\n' "$junit_report"

nextest_with_metadata() {
    if [ "$build_mode" = true ]; then
        export BUCK2_NEXTEST_DISPATCH_ALLOWED=1
        "$cargo_nextest_command" "$cargo_nextest_subcommand" "$@" --cargo-metadata "$private_root/meta/cargo-metadata.json" --binaries-metadata "$private_root/meta/binaries-metadata.json" --target-dir-remap "$private_root/target" --build-dir-remap "$private_root/target" --workspace-remap "$private_root/workspace"
    elif [ -n "$launcher" ]; then
        "$launcher" cargo nextest "$@" --cargo-metadata "$private_root/meta/cargo-metadata.json" --binaries-metadata "$private_root/meta/binaries-metadata.json" --target-dir-remap "$private_root/target" --build-dir-remap "$private_root/target" --workspace-remap "$private_root/workspace"
    else
        "$real_cargo_command" nextest "$@" --cargo-metadata "$private_root/meta/cargo-metadata.json" --binaries-metadata "$private_root/meta/binaries-metadata.json" --target-dir-remap "$private_root/target" --build-dir-remap "$private_root/target" --workspace-remap "$private_root/workspace"
    fi
}

cd "$private_root/workspace" || fail 'could not enter synthesized workspace'
printf 'buck2-nextest-adapter: exec cargo nextest list --message-format json (supplied metadata)\n'
nextest_with_metadata list --message-format json >"$private_root/list.json"
list_status=$?
if [ -n "${BUCK2_NEXTEST_LIST_FAULT_STATUS:-}" ] && [ "$list_status" -eq 0 ]; then
    printf 'top-level cargo nextest dispatch: nextest list\n' >>"$BUCK2_NEXTEST_DISPATCH_LOG"
    list_status=$BUCK2_NEXTEST_LIST_FAULT_STATUS
fi
if [ "$list_status" -ne 0 ]; then
    printf 'buck2-nextest-adapter: nextest list failed status=%s\n' "$list_status" >&2
    final_status=$list_status
    cleanup_and_exit "$final_status"
fi
if [ "$option_command_mode" = false ] && [ -n "${BUCK2_NEXTEST_DISPATCH_LOG:-}" ] && [ -z "${BUCK2_NEXTEST_LIST_FAULT_STATUS:-}" ] && [ -z "${BUCK2_NEXTEST_TEST_EXECUTOR:-}" ] && [ -z "${BUCK2_NEXTEST_EXPORT_FAULT_GATE:-}" ]; then
    [ -s "$BUCK2_NEXTEST_DISPATCH_LOG" ] || fail 'nextest dispatch sentinel did not record top-level cargo nextest'
fi
[ ! -s "$BUCK2_NEXTEST_NESTED_CARGO_LOG" ] || fail 'nested Cargo operation was attempted'
[ ! -s "$BUCK2_NEXTEST_COMPILER_LOG" ] || fail 'compiler invocation was attempted'
grep -F 'buck2_nextest_rust_test' "$private_root/list.json" >/dev/null 2>&1 || fail 'synthetic binary was not listed'
grep -F 'pass_case' "$private_root/list.json" >/dev/null 2>&1 || fail 'pass_case was not listed'
grep -F 'fail_case' "$private_root/list.json" >/dev/null 2>&1 || fail 'fail_case was not listed'
grep -F 'ignored_case' "$private_root/list.json" >/dev/null 2>&1 || fail 'ignored_case was not listed'
grep -F 'timeout_case' "$private_root/list.json" >/dev/null 2>&1 || fail 'timeout_case was not listed'

printf 'buck2-nextest-adapter: exec cargo nextest run --profile %s --filterset %s (supplied metadata)\n' "$profile" "$filterset"
output_mode=--success-output
[ "$filterset" = 'test(=fail_case)' ] && output_mode=--failure-output
state=RUNNING
nextest_with_metadata run --profile "$profile" --message-format human --filterset "$filterset" --no-tests "$no_tests" "$output_mode" immediate-final &
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
internal_report="$private_root/workspace/target/nextest/$profile/junit.xml"

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
    if ! $python_command -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$internal_report"
    then
        export_error='nextest JUnit report is not valid XML'
    else
        if ! export_output=$($python_command "$private_root/nextest_artifact.py" export-report --source "$internal_report" --destination "$junit_report" 2>&1); then
            export_error="${export_output:-could not atomically export JUnit report}"
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
