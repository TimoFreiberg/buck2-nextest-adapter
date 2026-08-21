#!/bin/sh
set -u

if [ "${1:-}" = --internal-run-vector ]; then
    [ "$#" -ge 4 ] || exit 2
    vector_file=$2
    tail_file=$3
    shift 3
    [ -r "$vector_file" ] && [ -r "$tail_file" ] || exit 2
    extra_file=$(mktemp "${TMPDIR:-/tmp}/buck2-nextest-vector.XXXXXX") || exit 2
    trap 'rm -f "$extra_file"' EXIT
    for extra_arg do
        printf '%s\n' "$extra_arg" >>"$extra_file"
    done
    set --
    while IFS= read -r vector_arg || [ -n "$vector_arg" ]; do
        set -- "$@" "$vector_arg"
    done <"$vector_file"
    while IFS= read -r tail_arg || [ -n "$tail_arg" ]; do
        set -- "$@" "$tail_arg"
    done <"$tail_file"
    while IFS= read -r extra_arg || [ -n "$extra_arg" ]; do
        set -- "$@" "$extra_arg"
    done <"$extra_file"
    rm -f "$extra_file"
    [ "$#" -gt 0 ] || exit 2
    exec "$@"
fi

private_root=
parser_root=
cleanup_done=false
child_pid=
child_pgid=
state=PRE_DISPATCH
final_status=2
pending_signal=
newline='
'

usage() {
    printf '%s\n' 'usage: adapter.sh buck-artifact --artifact PATH --manifest PATH --validator PATH --cargo-baseline PATH --binary-baseline PATH --tests-baseline PATH --junit-report PATH [--build-mode --cargo-argv ARG... --end-argv --python-argv ARG... --end-argv --cargo-nextest-argv ARG... --end-argv --bundle-json JSON --bundle-resources PATH... --end-bundle-resources --runtime-resource PATH --source-denial PATH --action-metadata-parser PATH] [--profile NAME] [--filter EXPRESSION] [--no-tests auto|pass|warn|fail] [--report-skipped default|ignored] [--timeout-seconds N]' >&2
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
        if [ -n "$parser_root" ] && [ -d "$parser_root" ]; then
            rm -rf "$parser_root"
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
adapter_self=$0
case "$adapter_self" in
    /*) ;;
    *) adapter_self=$invocation_cwd/$adapter_self ;;
esac
parser_root=$(mktemp -d "${TMPDIR:-/tmp}/buck2-nextest-parse.XXXXXX") || exit 2
parser_bundle_resources_file=
strict_action_mode=false
[ -n "${BUCK2_NEXTEST_ACTION_METADATA:-}" ] && strict_action_mode=true
mode=
build_mode=false
cargo_command=${BUCK2_NEXTEST_CARGO_COMMAND:-}
python_command=${BUCK2_NEXTEST_PYTHON_COMMAND:-}
python_command_explicit=false
cargo_nextest_command=${BUCK2_NEXTEST_CARGO_NEXTEST_COMMAND:-}
cargo_nextest_subcommand=${BUCK2_NEXTEST_CARGO_NEXTEST_SUBCOMMAND:-nextest}
cargo_launch_command=
cargo_nextest_launch_command=
python_launch_command=
cargo_argv_mode=false
python_argv_mode=false
cargo_nextest_argv_mode=false
cargo_argv_set=false
python_argv_set=false
cargo_nextest_argv_set=false
cargo_argv_file=
python_argv_file=
cargo_nextest_argv_file=
bundle_json=
bundle_resources_file=
bundle_resource_count=0
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
action_metadata_parser=${BUCK2_NEXTEST_ACTION_METADATA_PARSER:-}
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
            [ "$build_mode" = false ] || { [ "$strict_action_mode" = false ] || fail 'build mode requires --cargo-argv'; }
            cargo_command=$2
            option_command_mode=true
            shift 2
            ;;
        --python-command)
            [ "$#" -ge 2 ] || fail '--python-command requires a value'
            [ "$python_command_explicit" = false ] || fail 'python command specified more than once'
            [ "$build_mode" = false ] || { [ "$strict_action_mode" = false ] || fail 'build mode requires --python-argv'; }
            python_command=$2
            python_command_explicit=true
            option_command_mode=true
            shift 2
            ;;
        --cargo-nextest-command)
            [ "$#" -ge 3 ] || fail '--cargo-nextest-command requires a command and subcommand'
            [ -z "$cargo_nextest_command" ] || fail 'cargo-nextest command specified more than once'
            [ "$build_mode" = false ] || { [ "$strict_action_mode" = false ] || fail 'build mode requires --cargo-nextest-argv'; }
            cargo_nextest_command=$2
            cargo_nextest_subcommand=$3
            option_command_mode=true
            shift 3
            ;;
        --cargo-argv|--python-argv|--cargo-nextest-argv)
            argv_kind=$1
            case "$argv_kind" in
                --cargo-argv) argv_file=$parser_root/argv-cargo; argv_set=$cargo_argv_set; cargo_argv_mode=true ;;
                --python-argv) argv_file=$parser_root/argv-python; argv_set=$python_argv_set; python_argv_mode=true ;;
                *) argv_file=$parser_root/argv-cargo-nextest; argv_set=$cargo_nextest_argv_set; cargo_nextest_argv_mode=true ;;
            esac
            [ "$argv_set" = false ] || fail "$argv_kind specified more than once"
            shift
            : >"$argv_file" || fail "could not create $argv_kind storage"
            while [ "$#" -gt 0 ] && [ "$1" != --end-argv ]; do
                [ "$1" != --end-argv ] || fail 'argv delimiter is reserved'
                case "$1" in
                    *"$newline"*) fail 'argv elements may not contain newlines' ;;
                esac
                printf '%s\n' "$1" >>"$argv_file"
                shift
            done
            [ "$#" -gt 0 ] || fail "$argv_kind requires --end-argv"
            shift
            case "$argv_kind" in
                --cargo-argv) cargo_argv_file=$argv_file; cargo_argv_set=true ;;
                --python-argv) python_argv_file=$argv_file; python_argv_set=true ;;
                *) cargo_nextest_argv_file=$argv_file; cargo_nextest_argv_set=true ;;
            esac
            option_command_mode=true
            ;;
        --bundle-json)
            [ "$#" -ge 2 ] || fail '--bundle-json requires a value'
            [ -z "$bundle_json" ] || fail 'bundle JSON specified more than once'
            bundle_json=$2
            shift 2
            ;;
        --bundle-resources)
            [ "$#" -ge 2 ] || fail '--bundle-resources requires at least one path'
            [ -n "$bundle_resources_file" ] && fail 'bundle resources specified more than once'
            bundle_resources_file=$parser_root/bundle-resources
            parser_bundle_resources_file=$bundle_resources_file
            : >"$bundle_resources_file" || fail 'could not create bundle resource storage'
            shift
            while [ "$#" -gt 0 ] && [ "$1" != --end-bundle-resources ]; do
                printf '%s\n' "$1" >>"$bundle_resources_file"
                bundle_resource_count=$((bundle_resource_count + 1))
                shift
            done
            [ "$#" -gt 0 ] || fail 'bundle resources require --end-bundle-resources'
            [ "$bundle_resource_count" -gt 0 ] || fail 'bundle resources require at least one path'
            shift
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
        --action-metadata-parser)
            [ "$#" -ge 2 ] || fail '--action-metadata-parser requires a value'
            [ -z "$action_metadata_parser" ] || fail 'action metadata parser specified more than once'
            action_metadata_parser=$2
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
if [ "$build_mode" = true ] && [ -n "$bundle_json" ]; then
    strict_action_mode=true
fi
if [ "$build_mode" = true ]; then
    if [ "$strict_action_mode" = true ]; then
        [ "$cargo_argv_set" = true ] || fail 'build mode requires --cargo-argv'
        [ "$python_argv_set" = true ] || fail 'build mode requires --python-argv'
        [ "$cargo_nextest_argv_set" = true ] || fail 'build mode requires --cargo-nextest-argv'
        [ -n "$bundle_json" ] || fail 'build mode requires --bundle-json'
        [ -n "$bundle_resources_file" ] || fail 'build mode requires --bundle-resources'
        [ "$bundle_resource_count" -gt 0 ] || fail 'build mode requires at least one bundle resource'
        [ -r "$bundle_resources_file" ] || fail 'build mode bundle resource input list is missing'
    fi
    [ -n "$runtime_resource" ] || fail 'build mode requires --runtime-resource'
    [ -n "$source_denial_arg" ] || fail 'build mode requires --source-denial'
    if [ "$cargo_argv_set" = true ]; then
        cargo_command=$(sed -n '1p' "$cargo_argv_file") || fail 'invalid Cargo argv'
        cargo_launch_command=$cargo_command
    fi
    if [ "$python_argv_set" = true ]; then
        python_command=$(sed -n '1p' "$python_argv_file") || fail 'invalid Python argv'
        python_launch_command=$python_command
    fi
    if [ "$cargo_nextest_argv_set" = true ]; then
        cargo_nextest_command=$(sed -n '1p' "$cargo_nextest_argv_file") || fail 'invalid cargo-nextest argv'
        cargo_nextest_launch_command=$cargo_nextest_command
    fi
    if [ "$strict_action_mode" = true ]; then
        for command_path in cargo_command python_command cargo_nextest_command; do
            case "$command_path" in
                cargo_command) value=$cargo_command ;;
                python_command) value=$python_command ;;
                cargo_nextest_command) value=$cargo_nextest_command ;;
            esac
            case "$value" in
                /*) ;;
                *) value=$invocation_cwd/$value ;;
            esac
            case "$command_path" in
                cargo_command) cargo_command=$value; cargo_launch_command=$value ;;
                python_command) python_command=$value; python_launch_command=$value ;;
                cargo_nextest_command) cargo_nextest_command=$value; cargo_nextest_launch_command=$value ;;
            esac
        done
        cargo_nextest_subcommand=$(sed -n '2p' "$cargo_nextest_argv_file") || fail 'build mode cargo-nextest argv requires nextest'
        [ "$cargo_nextest_subcommand" = nextest ] || fail 'build mode requires nextest subcommand'
        tail -n +3 "$cargo_nextest_argv_file" >"$parser_root/cargo-nextest-tail" || fail 'could not read cargo-nextest argv'
        tail -n +2 "$cargo_argv_file" >"$parser_root/cargo-tail" || fail 'could not read Cargo argv'
        tail -n +2 "$python_argv_file" >"$parser_root/python-tail" || fail 'could not read Python argv'
        {
            printf '%s\n' "$cargo_command"
            cat "$parser_root/cargo-tail"
        } >"$parser_root/cargo-launch"
        {
            printf '%s\n' "$python_command"
            cat "$parser_root/python-tail"
        } >"$parser_root/python-launch"
        {
            printf '%s\n' "$cargo_nextest_command"
            printf '%s\n' "$cargo_nextest_subcommand"
            cat "$parser_root/cargo-nextest-tail"
        } >"$parser_root/cargo-nextest-launch"
    fi
else
    [ -n "$python_command" ] || python_command=python3
fi
if [ "$build_mode" = true ]; then
    [ -n "$cargo_command" ] || fail 'build mode requires --cargo-command'
    [ -n "$python_command" ] || fail 'build mode requires --python-command'
    [ -n "$cargo_nextest_command" ] || fail 'build mode requires --cargo-nextest-command'
fi
python_run() {
    if [ "$strict_action_mode" = true ]; then
        "$adapter_self" --internal-run-vector "$parser_root/python-launch" /dev/null "$@"
    else
        "$python_command" "$@"
    fi
}
config_error=$(python_run - "$profile" "$filterset" "$no_tests" "$report_skipped" "$timeout_seconds" <<'PY'
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
    [ -n "$action_metadata_parser" ] || fail 'build mode requires --action-metadata-parser'
    for value_name in runtime_resource source_denial_arg action_metadata_parser; do
        case "$value_name" in
            runtime_resource) value=$runtime_resource ;;
            source_denial_arg) value=$source_denial_arg ;;
            action_metadata_parser) value=$action_metadata_parser ;;
        esac
        case "$value" in
            /*) ;;
            */*) value=$invocation_cwd/$value ;;
        esac
        case "$value_name" in
            runtime_resource) runtime_resource=$value ;;
            source_denial_arg) source_denial_arg=$value ;;
            action_metadata_parser) action_metadata_parser=$value ;;
        esac
    done
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
if [ "$build_mode" = true ]; then
    [ -n "$cargo_command" ] || fail 'build mode requires --cargo-command'
    [ -n "$python_command" ] || fail 'build mode requires --python-command'
    [ -n "$cargo_nextest_command" ] || fail 'build mode requires --cargo-nextest-command'
    for input in "$cargo_command" "$python_command" "$cargo_nextest_command" "$runtime_resource" "$source_denial_arg" "$action_metadata_parser"; do
        [ -r "$input" ] && [ -f "$input" ] && [ ! -L "$input" ] || fail "declared build resource is not a readable regular file: $input"
    done
    if [ "$strict_action_mode" = true ]; then
        while IFS= read -r argv_value; do
            [ -n "$argv_value" ] || fail 'declared argv contains an empty executable'
            [ "$argv_value" != --end-argv ] || fail 'argv delimiter is reserved'
        done <"$cargo_argv_file"
        while IFS= read -r argv_value; do
            [ -n "$argv_value" ] || fail 'declared argv contains an empty executable'
            [ "$argv_value" != --end-argv ] || fail 'argv delimiter is reserved'
        done <"$python_argv_file"
        while IFS= read -r argv_value; do
            [ "$argv_value" != --end-argv ] || fail 'argv delimiter is reserved'
        done <"$cargo_nextest_argv_file"
    fi
    [ -x "$cargo_command" ] || fail "declared Cargo command is not executable: $cargo_command"
    [ -x "$python_command" ] || fail "declared Python command is not executable: $python_command"
    [ -x "$cargo_nextest_command" ] || fail "declared cargo-nextest command is not executable: $cargo_nextest_command"
else
    if [ "$option_command_mode" = false ]; then
    command -v cargo >/dev/null 2>&1 || fail 'cargo is not available on PATH'
    command -v python3 >/dev/null 2>&1 || fail 'python3 is not available on PATH'
        real_cargo_command=$(command -v cargo)
    fi
fi

junit_report=$(python_run - "$invocation_cwd" "$junit_report" <<'PY'
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

if [ -n "${BUCK_SCRATCH_PATH:-}" ]; then
    scratch_parent=$BUCK_SCRATCH_PATH
    case "$scratch_parent" in
        /*) ;;
        *) scratch_parent=$invocation_cwd/$scratch_parent ;;
    esac
    [ -d "$scratch_parent" ] || fail 'BUCK_SCRATCH_PATH is not an existing directory'
else
    scratch_parent=${TMPDIR:-/tmp}
fi
private_root=$(mktemp -d "$scratch_parent/buck2-nextest-buck-artifact.XXXXXX") || fail "could not create private root under $scratch_parent"
parser_bundle_resources_file=$bundle_resources_file
mkdir -p "$private_root/workspace/src" "$private_root/workspace/.config" "$private_root/target/debug/deps" "$private_root/cargo-home" "$private_root/bundle" || fail 'could not create private staging directories'
cp "$manifest_input" "$private_root/manifest.json" || fail 'could not stage manifest'
cp "$validator_script" "$private_root/nextest_artifact.py" || fail 'could not stage validator'
cp "$baseline_cargo" "$private_root/baseline-cargo.json" || fail 'could not stage Cargo baseline'
cp "$baseline_binaries" "$private_root/baseline-binaries.json" || fail 'could not stage binary baseline'
cp "$baseline_tests" "$private_root/baseline-tests.json" || fail 'could not stage tests baseline'

source_denial=$source_denial_arg
if [ -z "$source_denial" ] && [ "$build_mode" = false ]; then
    source_denial="$resource_root/tools/cargo_source_denial.sh"
    [ -r "$source_denial" ] || source_denial="$resource_root/cargo_source_denial.sh"
fi
[ -r "$source_denial" ] && [ -f "$source_denial" ] && [ ! -L "$source_denial" ] || fail "source-denial helper is not declared: $source_denial"
cp "$source_denial" "$private_root/cargo" || fail 'could not stage source-denial cargo wrapper'
cp "$source_denial" "$private_root/rustc" || fail 'could not stage source-denial rustc wrapper'
chmod +x "$private_root/cargo" "$private_root/rustc" || fail 'could not make source-denial wrappers executable'

if [ "$build_mode" = true ] && [ "$strict_action_mode" = true ]; then
    bundle_env_file=$private_root/bundle-environment
    : >"$bundle_env_file"
    bundle_error=$(python_run - "$bundle_json" "$parser_bundle_resources_file" "$private_root/bundle" "$bundle_env_file" <<'PY'
import hashlib
import json
import os
import shutil
import shlex
import stat
import sys
from pathlib import Path

raw, resource_file, bundle_root, env_file = sys.argv[1:]
try:
    data = json.loads(raw)
except (TypeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"bundle JSON is invalid: {exc}")
if set(data) != {"bundle_version", "bundle_platform", "bundle_resources", "bundle_environment"} or data["bundle_version"] != 1:
    raise SystemExit("unsupported bundle schema")
platform = data["bundle_platform"]
if not isinstance(platform, str) or not platform or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:/" for c in platform):
    raise SystemExit("bundle platform identity is invalid")

def rel(value, label, allow_empty=False):
    if not isinstance(value, str) or (not allow_empty and not value) or "\x00" in value or "\\" in value or value.startswith("/"):
        raise SystemExit(f"{label} is not a normalized relative POSIX path")
    parts = value.split("/")
    if any(not part or part in (".", "..") for part in parts):
        raise SystemExit(f"{label} contains traversal")
    return value

resources = data["bundle_resources"]
if not isinstance(resources, list):
    raise SystemExit("bundle resources must be a list")
try:
    provided = [line.rstrip("\n") for line in Path(resource_file).read_text(encoding="utf-8").splitlines()]
except FileNotFoundError:
    raise SystemExit("bundle resource input list is missing")
seen_source = set()
seen_path = set()
root = Path(bundle_root)
for index, item in enumerate(resources):
    if not isinstance(item, dict) or set(item) != {"source", "path", "digest"}:
        raise SystemExit(f"bundle resource {index} has invalid fields")
    source = rel(item["source"], f"bundle resource {index} source")
    path = rel(item["path"], f"bundle resource {index} path")
    digest = item["digest"]
    parts = digest.split(":") if isinstance(digest, str) else []
    if len(parts) != 3 or parts[0] != "sha256" or len(parts[1]) != 64 or not parts[2].isdigit() or any(c not in "0123456789abcdefABCDEF" for c in parts[1]):
        raise SystemExit(f"bundle resource {index} digest is invalid")
    if source in seen_source or path in seen_path:
        raise SystemExit("bundle resource source/path is duplicated")
    matching = [candidate for candidate in provided if candidate == source or Path(candidate).name == Path(source).name]
    if len(matching) != 1:
        raise SystemExit(f"bundle resource source is not a unique declared action input: {source}")
    seen_source.add(source); seen_path.add(path)
    source_path = Path(matching[0])
    if not source_path.is_absolute():
        source_path = Path.cwd() / source_path
    if source_path.is_symlink() or not source_path.is_file():
        raise SystemExit(f"bundle resource source is not a regular file: {source}")
    actual_size = source_path.stat().st_size
    h = hashlib.sha256(source_path.read_bytes()).hexdigest()
    if f"sha256:{h}:{actual_size}" != digest:
        raise SystemExit(f"bundle resource digest mismatch: {source}")
    destination = root / path
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source_path, destination)
    mode = destination.stat().st_mode
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise SystemExit(f"staged bundle resource is not regular: {path}")
    if f"sha256:{hashlib.sha256(destination.read_bytes()).hexdigest()}:{destination.stat().st_size}" != digest:
        raise SystemExit(f"staged bundle resource digest mismatch: {path}")

environment = data["bundle_environment"]
if not isinstance(environment, list):
    raise SystemExit("bundle environment must be a list")
seen_names = set()
reserved = {"PATH", "HOME", "TMPDIR", "CARGO_HOME", "CARGO_TARGET_DIR", "CARGO_MANIFEST_DIR"}
for index, item in enumerate(environment):
    if not isinstance(item, dict) or set(item) != {"name", "kind", "value"}:
        raise SystemExit(f"bundle environment {index} has invalid fields")
    name, kind, value = item["name"], item["kind"], item["value"]
    if not isinstance(name, str) or not name or not (("a" <= name[0] <= "z") or ("A" <= name[0] <= "Z") or name[0] == "_") or any(not (("a" <= c <= "z") or ("A" <= c <= "Z") or ("0" <= c <= "9") or c == "_") for c in name) or name in seen_names or name in reserved or name.startswith("BUCK2_NEXTEST_"):
        raise SystemExit(f"bundle environment name is invalid: {name!r}")
    if kind not in ("literal", "relative_path") or not isinstance(value, str) or "\x00" in value:
        raise SystemExit(f"bundle environment {index} is invalid")
    if kind == "relative_path":
        value = rel(value, f"bundle environment {index} value")
        resolved = root / value
        if resolved.is_symlink() or not resolved.is_file():
            raise SystemExit(f"bundle environment path is not staged: {value}")
        value = str(resolved)
    with open(env_file, "a", encoding="utf-8") as stream:
        stream.write("export " + name + "=" + shlex.quote(value) + "\n")
    seen_names.add(name)
PY
) || fail "$bundle_error"
    . "$bundle_env_file" || fail 'could not apply staged bundle environment'
    if [ -n "${BUCK2_NEXTEST_BUNDLE_ENV_LOG:-}" ]; then
        printf '%s\n' "${BUNDLE_FIXTURE_PATH:-}" >"$BUCK2_NEXTEST_BUNDLE_ENV_LOG"
    fi
fi

if [ "$build_mode" = true ] && [ -n "${BUCK2_NEXTEST_ACTION_METADATA:-}" ]; then
    metadata_path=${BUCK2_NEXTEST_ACTION_METADATA}
    [ -n "$action_metadata_parser" ] || fail 'build mode requires --action-metadata-parser'
    case "$metadata_path" in
        /*) ;;
        *) metadata_path=$invocation_cwd/$metadata_path ;;
    esac
    [ -r "$metadata_path" ] && [ -f "$metadata_path" ] && [ ! -L "$metadata_path" ] || fail 'action metadata file is not readable'
    python_run "$action_metadata_parser" --metadata "$metadata_path" \
        --adapter "$0" --cargo-nextest "$cargo_nextest_command" --python "$python_command" \
        --cargo "$cargo_command" --source-denial "$source_denial" --validator "$validator_script" \
        --cargo-baseline "$baseline_cargo" --binary-baseline "$baseline_binaries" --tests-baseline "$baseline_tests" \
        --runtime-resource "$runtime_resource" --manifest "$manifest_input" --artifact "$artifact" || fail 'action metadata validation failed'
fi

python_run "$private_root/nextest_artifact.py" validate-manifest --manifest "$private_root/manifest.json" --root "$private_root" --allow-missing || fail 'manifest validation failed'
if [ "$build_mode" = true ]; then
    resource_root=$private_root/resources
    mkdir -p "$private_root/resources/runtime"
    cp "$runtime_resource" "$private_root/resources/runtime/buck2_artifact_runtime.txt" || fail 'could not stage declared runtime resource'
fi
python_run "$private_root/nextest_artifact.py" stage-runtime --manifest "$private_root/manifest.json" --root "$private_root" --resources "$resource_root" || fail 'runtime staging failed'
executable_rel=$(python_run -c 'import json,sys; print(json.load(open(sys.argv[1]))["paths"]["executable"])' "$private_root/manifest.json") || fail 'could not read executable path'
working_rel=$(python_run -c 'import json,sys; print(json.load(open(sys.argv[1]))["paths"]["working_directory"])' "$private_root/manifest.json") || fail 'could not read working-directory path'
executable_stage="$private_root/$executable_rel"
working_stage="$private_root/$working_rel"
mkdir -p "$(dirname "$executable_stage")" "$working_stage" || fail 'could not create declared staging paths'
cp "$artifact" "$executable_stage" || fail 'could not stage declared artifact'
chmod +x "$executable_stage" || fail 'could not make staged artifact executable'
python_run "$private_root/nextest_artifact.py" validate-manifest --manifest "$private_root/manifest.json" --root "$private_root" || fail 'staged manifest validation failed'
python_run "$private_root/nextest_artifact.py" synthesize --cargo-baseline "$private_root/baseline-cargo.json" --binary-baseline "$private_root/baseline-binaries.json" --tests-baseline "$private_root/baseline-tests.json" --target-dir "$private_root/target" --workspace "$private_root/workspace" --output-dir "$private_root/meta" --manifest "$private_root/manifest.json" --manifest-root "$private_root" || fail 'metadata synthesis failed'
cp "$executable_stage" "$private_root/target/debug/deps/buck2_nextest_rust_test" || fail 'could not install staged test executable'
chmod +x "$private_root/target/debug/deps/buck2_nextest_rust_test" || fail 'could not make installed test executable executable'
environment_file=$parser_root/manifest-environment
python_run "$private_root/nextest_artifact.py" emit-environment --manifest "$private_root/manifest.json" --root "$private_root" >"$environment_file" || fail 'could not emit manifest environment'
. "$environment_file"

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
    case "$log_name" in
        BUCK2_NEXTEST_DISPATCH_LOG) log_value=$BUCK2_NEXTEST_DISPATCH_LOG ;;
        BUCK2_NEXTEST_PROBE_LOG) log_value=$BUCK2_NEXTEST_PROBE_LOG ;;
        BUCK2_NEXTEST_NESTED_CARGO_LOG) log_value=$BUCK2_NEXTEST_NESTED_CARGO_LOG ;;
        BUCK2_NEXTEST_COMPILER_LOG) log_value=$BUCK2_NEXTEST_COMPILER_LOG ;;
    esac
    case "$log_value" in
        /*) ;;
        *) log_value=$invocation_cwd/$log_value ;;
    esac
    case "$log_name" in
        BUCK2_NEXTEST_DISPATCH_LOG) export BUCK2_NEXTEST_DISPATCH_LOG=$log_value ;;
        BUCK2_NEXTEST_PROBE_LOG) export BUCK2_NEXTEST_PROBE_LOG=$log_value ;;
        BUCK2_NEXTEST_NESTED_CARGO_LOG) export BUCK2_NEXTEST_NESTED_CARGO_LOG=$log_value ;;
        BUCK2_NEXTEST_COMPILER_LOG) export BUCK2_NEXTEST_COMPILER_LOG=$log_value ;;
    esac
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
run_vector() {
    vector_file=$1
    tail_file=$2
    shift 2
    "$adapter_self" --internal-run-vector "$vector_file" "$tail_file" "$@"
}
if [ "$build_mode" = true ] && [ "$strict_action_mode" = true ]; then
    help_output=$(run_vector "$parser_root/cargo-nextest-launch" /dev/null run --help 2>&1) || fail 'cargo nextest is not available'
elif [ "$build_mode" = true ]; then
    help_output=$("$cargo_nextest_command" "$cargo_nextest_subcommand" run --help 2>&1) || fail 'cargo nextest is not available'
elif [ "$option_command_mode" = true ]; then
    help_output=$("$cargo_command" nextest run --help 2>&1) || fail 'cargo nextest is not available'
else
    help_output=$("$real_cargo_command" nextest run --help 2>&1) || fail 'cargo nextest is not available'
fi
for flag in --filterset --cargo-metadata --binaries-metadata --target-dir-remap --workspace-remap --build-dir-remap --success-output --failure-output --profile --no-tests; do
    printf '%s\n' "$help_output" | grep -F -- "$flag" >/dev/null 2>&1 || fail "cargo nextest run does not expose $flag"
done
if [ "$build_mode" = true ] && [ "$strict_action_mode" = true ]; then
    list_help=$(run_vector "$parser_root/cargo-nextest-launch" /dev/null list --help 2>&1) || fail 'cargo nextest is not available'
elif [ "$build_mode" = true ]; then
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
    if [ "$build_mode" = true ] && [ "$strict_action_mode" = true ]; then
        export BUCK2_NEXTEST_DISPATCH_ALLOWED=1
        run_vector "$parser_root/cargo-nextest-launch" /dev/null "$@" --cargo-metadata "$private_root/meta/cargo-metadata.json" --binaries-metadata "$private_root/meta/binaries-metadata.json" --target-dir-remap "$private_root/target" --build-dir-remap "$private_root/target" --workspace-remap "$private_root/workspace"
    elif [ "$build_mode" = true ]; then
        export BUCK2_NEXTEST_DISPATCH_ALLOWED=1
        "$cargo_nextest_command" "$cargo_nextest_subcommand" "$@" --cargo-metadata "$private_root/meta/cargo-metadata.json" --binaries-metadata "$private_root/meta/binaries-metadata.json" --target-dir-remap "$private_root/target" --build-dir-remap "$private_root/target" --workspace-remap "$private_root/workspace"
    elif [ -n "$launcher" ]; then
        "$launcher" cargo nextest "$@" --cargo-metadata "$private_root/meta/cargo-metadata.json" --binaries-metadata "$private_root/meta/binaries-metadata.json" --target-dir-remap "$private_root/target" --build-dir-remap "$private_root/target" --workspace-remap "$private_root/workspace"
    elif [ "$option_command_mode" = true ]; then
        "$cargo_command" nextest "$@" --cargo-metadata "$private_root/meta/cargo-metadata.json" --binaries-metadata "$private_root/meta/binaries-metadata.json" --target-dir-remap "$private_root/target" --build-dir-remap "$private_root/target" --workspace-remap "$private_root/workspace"
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
if [ "$build_mode" = true ] && [ "$strict_action_mode" = true ] && [ -n "$launcher" ]; then
    "$launcher" "$adapter_self" --internal-run-vector "$parser_root/cargo-nextest-launch" /dev/null run --profile "$profile" --message-format human --filterset "$filterset" --no-tests "$no_tests" "$output_mode" immediate-final --cargo-metadata "$private_root/meta/cargo-metadata.json" --binaries-metadata "$private_root/meta/binaries-metadata.json" --target-dir-remap "$private_root/target" --build-dir-remap "$private_root/target" --workspace-remap "$private_root/workspace" &
elif [ "$build_mode" = true ] && [ -n "$launcher" ]; then
    "$launcher" "$cargo_nextest_command" "$cargo_nextest_subcommand" run --profile "$profile" --message-format human --filterset "$filterset" --no-tests "$no_tests" "$output_mode" immediate-final --cargo-metadata "$private_root/meta/cargo-metadata.json" --binaries-metadata "$private_root/meta/binaries-metadata.json" --target-dir-remap "$private_root/target" --build-dir-remap "$private_root/target" --workspace-remap "$private_root/workspace" &
elif [ "$build_mode" = true ] && [ "$strict_action_mode" = true ]; then
    run_vector "$parser_root/cargo-nextest-launch" /dev/null run --profile "$profile" --message-format human --filterset "$filterset" --no-tests "$no_tests" "$output_mode" immediate-final --cargo-metadata "$private_root/meta/cargo-metadata.json" --binaries-metadata "$private_root/meta/binaries-metadata.json" --target-dir-remap "$private_root/target" --build-dir-remap "$private_root/target" --workspace-remap "$private_root/workspace" &
elif [ "$build_mode" = true ]; then
    "$cargo_nextest_command" "$cargo_nextest_subcommand" run --profile "$profile" --message-format human --filterset "$filterset" --no-tests "$no_tests" "$output_mode" immediate-final --cargo-metadata "$private_root/meta/cargo-metadata.json" --binaries-metadata "$private_root/meta/binaries-metadata.json" --target-dir-remap "$private_root/target" --build-dir-remap "$private_root/target" --workspace-remap "$private_root/workspace" &
else
    nextest_with_metadata run --profile "$profile" --message-format human --filterset "$filterset" --no-tests "$no_tests" "$output_mode" immediate-final &
fi
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
    if ! python_run -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$internal_report"
    then
        export_error='nextest JUnit report is not valid XML'
    else
        if ! export_output=$(python_run "$private_root/nextest_artifact.py" export-report --source "$internal_report" --destination "$junit_report" 2>&1); then
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
