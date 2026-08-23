#!/bin/sh
# Repository-level declared-input relocation assurance check.
set -u

root=${BUCK_PROJECT_ROOT:-${BUCK_DEFAULT_RUNTIME_RESOURCES:-$(cd "$(dirname "$0")" && pwd -P)}}
artifact=$1
manifest=$2
validator=$3
cargo_baseline=$4
binary_baseline=$5
tests_baseline=$6
python_executable=$7
nextest_executable=$8

run_root=
status=0
phase=initialization
cleanup_done=0
fail_status=0
artifact_raw=${ADAPTER_RELOCATED_ARTIFACT_BUCK_OUTPUT_PATH:-$artifact}
manifest_raw=${ADAPTER_RELOCATED_MANIFEST_BUCK_OUTPUT_PATH:-$manifest}
python_raw=${ADAPTER_RELOCATED_PYTHON_BUCK_OUTPUT_PATH:-$python_executable}
nextest_raw=${ADAPTER_RELOCATED_NEXTEST_BUCK_OUTPUT_PATH:-$nextest_executable}

lexical_path() {
    raw=$1
    case "$raw" in
        /*) printf '%s\n' "$raw" ;;
        *[\\]*|*/../*|../*|*/..|.|./*|*/./*|*/.) return 1 ;;
        *) printf '%s/%s\n' "$root" "$raw" ;;
    esac
}

validate_parent_chain() {
    path=$1
    case "$path" in
        "$root"/*) ;;
        *) return 1 ;;
    esac
    parent=$(dirname "$path")
    while [ "$parent" != "$root" ]; do
        [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
        parent=$(dirname "$parent")
    done
}

fail_phase() {
    fail_status=${2:-1}
    printf 'adapter relocated: phase=%s message=%s\n' "$1" "${3:-phase failed}" >&2
    for file in out probe dispatch argv.jsonl identity buck_outputs observability; do
        path="$run_root/$file"
        printf 'adapter relocated: %s=%s\n' "$file" "$path" >&2
        [ -f "$path" ] && cat "$path" >&2 || true
    done
    if [ -n "${ADAPTER_RELOCATED_DIAGNOSTIC_DIR:-}" ] && [ -n "$run_root" ] && [ -d "$run_root" ]; then
        mkdir -p "$ADAPTER_RELOCATED_DIAGNOSTIC_DIR" 2>/dev/null || true
        for file in out probe dispatch argv.jsonl identity buck_outputs observability; do
            cp "$run_root/$file" "$ADAPTER_RELOCATED_DIAGNOSTIC_DIR/$file" 2>/dev/null || true
        done
    fi
    phase=$1
    return 0
}

cleanup() {
    cleanup_status=0
    [ "$cleanup_done" -eq 0 ] || return 0
    cleanup_done=1
    if [ "${ADAPTER_RELOCATED_TEST_FAIL_PHASE:-}" = cleanup ]; then
        printf 'adapter relocated: phase=cleanup message=injected cleanup failure\n' >&2
        if [ -n "${ADAPTER_RELOCATED_DIAGNOSTIC_DIR:-}" ] && [ -n "$run_root" ] && [ -d "$run_root" ]; then
            mkdir -p "$ADAPTER_RELOCATED_DIAGNOSTIC_DIR" 2>/dev/null || true
            for file in out probe dispatch argv.jsonl identity buck_outputs observability; do
                cp "$run_root/$file" "$ADAPTER_RELOCATED_DIAGNOSTIC_DIR/$file" 2>/dev/null || true
            done
        fi
        return 70
    fi
    if [ -n "$run_root" ] && [ -e "$run_root" ]; then
        rm -rf "$run_root" || cleanup_status=$?
    fi
    return "$cleanup_status"
}

on_exit() {
    trap - EXIT
    cleanup_status=0
    cleanup || cleanup_status=$?
    if [ "$fail_status" -ne 0 ]; then
        exit "$fail_status"
    fi
    if [ "$cleanup_status" -ne 0 ]; then
        exit "$cleanup_status"
    fi
    exit "$status"
}
trap on_exit EXIT

# Initialization creates all diagnostic files before setup can fail.
run_root=$(mktemp -d "${TMPDIR:-/tmp}/adapter-relocated.XXXXXX") || { fail_phase initialization 1 'could not create run root'; exit 1; }
run_root=$(cd "$run_root" && pwd -P) || { fail_phase initialization 1 'could not resolve run root'; exit 1; }
for file in out probe dispatch argv.jsonl identity buck_outputs observability; do : >"$run_root/$file" || { fail_phase initialization 1 "could not initialize $file"; exit 1; }; done
bin="$run_root/bin"
scratch="$run_root/buck-scratch"
relocated="$run_root/relocated"
mkdir "$bin" "$scratch" "$relocated" || { fail_phase initialization 1 'could not create run directories'; exit 1; }
mkdir -p "$run_root/ambient-tmp" "$run_root/home" "$run_root/records" || { fail_phase initialization 1 'could not create private directories'; exit 1; }
report="$run_root/report.xml"
out="$run_root/out"
probe="$run_root/probe"
dispatch="$run_root/dispatch"
argv_log="$run_root/argv.jsonl"
record_helper="$root/tools/nextest_relocated_records.py"

# Preserve raw Buck output and derive paths lexically without resolving symlinks.
write_buck_output() {
    label=$1; raw=$2; derived=$3; executable=$4
    digest_value=$($checksum_command "$derived" 2>/dev/null | awk '{print $1}') || return 1
    printf 'target=%s\nraw=%s\nderived=%s\ndigest=%s\nexecutable=%s\n' "$label" "$raw" "$derived" "$digest_value" "$executable" >>"$run_root/buck_outputs"
}
checksum_command=
if command -v sha256sum >/dev/null 2>&1; then checksum_command=sha256sum; else checksum_command=shasum; fi
artifact_path=$(lexical_path "$artifact_raw") || { fail_phase setup 1 'invalid artifact Buck output path'; exit 1; }
manifest_path=$(lexical_path "$manifest_raw") || { fail_phase setup 1 'invalid manifest Buck output path'; exit 1; }
python_path=$(lexical_path "$python_raw") || { fail_phase setup 1 'invalid Python Buck output path'; exit 1; }
nextest_path=$(lexical_path "$nextest_raw") || { fail_phase setup 1 'invalid nextest Buck output path'; exit 1; }
for item in "$artifact_path" "$manifest_path" "$python_path" "$nextest_path"; do
    case "$item" in "$root"/*) ;; *) fail_phase setup 1 "Buck output escaped project root: $item"; exit 1 ;; esac
    validate_parent_chain "$item" || { fail_phase setup 1 "Buck output has invalid parent chain: $item"; exit 1; }
    if [ ! -f "$item" ] || [ -L "$item" ]; then fail_phase setup 1 "Buck output is not a regular non-symlink file: $item"; exit 1; fi
done
[ -x "$python_path" ] && [ -x "$nextest_path" ] || { fail_phase setup 1 'Buck-produced tool output is not executable'; exit 1; }
python_digest=$($checksum_command "$python_path" 2>/dev/null | awk '{print $1}') || { fail_phase setup 1 'could not digest Python Buck output'; exit 1; }
nextest_digest=$($checksum_command "$nextest_path" 2>/dev/null | awk '{print $1}') || { fail_phase setup 1 'could not digest nextest Buck output'; exit 1; }
{
    printf 'python_buck_output_path=%s\n' "$python_raw"
    printf 'python_buck_output_digest=%s\n' "$python_digest"
    printf 'nextest_buck_output_path=%s\n' "$nextest_raw"
    printf 'nextest_buck_output_digest=%s\n' "$nextest_digest"
} >>"$run_root/identity"
write_buck_output '//:buck2_nextest_rust_test' "$artifact_raw" "$artifact_path" no || { fail_phase setup 1 'could not record artifact Buck output'; exit 1; }
write_buck_output '//:buck2_nextest_artifact_manifest' "$manifest_raw" "$manifest_path" no || { fail_phase setup 1 'could not record manifest Buck output'; exit 1; }
write_buck_output '//:nextest-python-executable' "$python_raw" "$python_path" yes || { fail_phase setup 1 'could not record Python Buck output'; exit 1; }
write_buck_output '//:nextest-cargo-nextest-v1-executable' "$nextest_raw" "$nextest_path" yes || { fail_phase setup 1 'could not record nextest Buck output'; exit 1; }

# Setup is deliberately controlled so every failure gets a phase diagnostic.
phase=setup
for utility in sh env mkdir cp chmod mktemp dirname rm grep sed cat basename tr wc bash realpath awk cut tail ln; do
    utility_path=$(command -v "$utility" 2>/dev/null) || { fail_phase setup 1 "missing utility: $utility"; exit 1; }
    ln -s "$utility_path" "$bin/$utility" || { fail_phase setup 1 "could not stage utility: $utility"; exit 1; }
done
ln -s "$(command -v "$checksum_command")" "$bin/$checksum_command" || { fail_phase setup 1 'could not stage checksum utility'; exit 1; }
ln -s "$(command -v python3)" "$bin/python3" || { fail_phase setup 1 'could not stage python3'; exit 1; }
old_cwd=$(pwd -P)
cd "$relocated" || { fail_phase setup 1 'could not enter relocated cwd'; exit 1; }
if [ "${ADAPTER_RELOCATED_TEST_FAIL_PHASE:-}" = setup ]; then fail_phase setup 1 'injected setup failure'; exit 1; fi

phase=adapter
adapter_status=0
if [ "${ADAPTER_RELOCATED_TEST_FAIL_PHASE:-}" = adapter ]; then
    fail_phase adapter 1 'injected adapter failure'
    exit 1
fi
PATH="$bin" HOME="$run_root/home" TMPDIR="$run_root/ambient-tmp" BUCK_PROJECT_ROOT="$root" \
BUCK_SCRATCH_PATH="$scratch" BUCK_DEFAULT_RUNTIME_RESOURCES="$root" \
BUCK2_NEXTEST_PROBE_LOG="$probe" BUCK2_NEXTEST_DISPATCH_LOG="$dispatch" \
BUCK2_NEXTEST_ARGV_LOG="$argv_log" \
BUCK2_NEXTEST_REAL_CARGO="$root/tools/cargo_source_denial.sh" BUCK2_NEXTEST_DISPATCH_ALLOWED=1 \
BUCK2_NEXTEST_NESTED_CARGO_LOG="$run_root/nested-cargo.log" \
BUCK2_NEXTEST_COMPILER_LOG="$run_root/compiler.log" \
ADAPTER_RELOCATED_RECORD_HELPER="$root/tools/nextest_relocated_records.py" ADAPTER_RELOCATED_RECORD_DIR="$run_root/records" \
ADAPTER_RELOCATED_IDENTITY_FILE="$run_root/identity" ADAPTER_RELOCATED_OBSERVABILITY_DIR="$run_root/records" \
ADAPTER_RELOCATED_RECORD_PREFIX="$run_root/records/record" \
BUCK2_NEXTEST_REQUIRE_PROCESS_GROUP= BUCK2_NEXTEST_EXPORT_FAULT_GATE= BUCK2_NEXTEST_EXPORT_FAULT_MARKER= \
"$root/adapter.sh" buck-artifact --build-mode \
    --artifact "$artifact_path" --manifest "$manifest_path" --validator "$validator" \
    --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" \
    --cargo-command "$root/tools/cargo_source_denial.sh" --python-command "$python_path" \
    --cargo-nextest-command "$nextest_path" nextest \
    --runtime-resource "$root/runtime/buck2_artifact_runtime.txt" \
    --source-denial "$root/tools/cargo_source_denial.sh" \
    --action-metadata-parser "$root/tools/nextest_buck_artifact_action_metadata.py" \
    --junit-report "$report" >"$out" 2>&1
adapter_status=$?
cd "$old_cwd" || true
if [ "$adapter_status" -ne 0 ]; then fail_phase adapter "$adapter_status" 'adapter returned nonzero'; exit "$adapter_status"; fi

phase=postrun
if [ "${ADAPTER_RELOCATED_TEST_FAIL_PHASE:-}" = postrun ]; then fail_phase postrun 1 'injected postrun failure'; exit 1; fi
[ -s "$report" ] || { fail_phase postrun 1 'JUnit report was not exported'; exit 1; }
[ ! -s "$probe" ] || { fail_phase postrun 1 'nextest probe log was not empty'; exit 1; }
[ -s "$dispatch" ] || { fail_phase postrun 1 'dispatch log was empty'; exit 1; }
[ -s "$argv_log" ] || { fail_phase postrun 1 'argv log was empty'; exit 1; }
grep -F 'buck2-nextest-adapter: junit-report=' "$run_root/out" >/dev/null || { fail_phase postrun 1 'JUnit diagnostic was absent'; exit 1; }
private_root=$(sed -n 's/.*cleanup=once root=//p' "$run_root/out")
case "$private_root" in "$scratch"/*) ;; *) fail_phase postrun 1 'adapter private root escaped Buck scratch'; exit 1 ;; esac
[ ! -e "$private_root" ] || { fail_phase postrun 1 'adapter private root was not cleaned'; exit 1; }
[ ! -e "$run_root/ambient-tmp/buck2-nextest-buck-artifact" ] || { fail_phase postrun 1 'ambient temporary root was created'; exit 1; }
[ "$(grep -c 'cleanup=once' "$run_root/out")" -eq 1 ] || { fail_phase postrun 1 'cleanup marker count was not one'; exit 1; }
[ ! -s "$run_root/nested-cargo.log" ] && [ ! -s "$run_root/compiler.log" ] || { fail_phase postrun 1 'nested Cargo/compiler activity was observed'; exit 1; }

# Merge process-local identity/observability records after all child processes exit.
PATH="$bin" env -u ADAPTER_RELOCATED_RECORD_HELPER -u ADAPTER_RELOCATED_RECORD_DIR \
    "$python_path" "$record_helper" merge "$run_root/records" "$run_root/identity" "$run_root/observability" \
    || { fail_phase postrun 1 'process records failed validation'; exit 1; }
for key in process phase sequence cwd path checksum_command; do grep -F "$key=" "$run_root/observability" >/dev/null || { fail_phase postrun 1 "observability key missing: $key"; exit 1; }; done
grep -F "checksum_command=$checksum_command" "$run_root/observability" >/dev/null || { fail_phase postrun 1 'checksum implementation was not observed'; exit 1; }
[ "$(wc -l <"$run_root/identity" | tr -d ' ')" -eq 10 ] || { fail_phase postrun 1 'identity schema did not contain ten fields'; exit 1; }

printf '%s\n' 'adapter relocated sanitized: passed'
exit 0
