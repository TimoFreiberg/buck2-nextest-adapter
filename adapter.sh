#!/bin/sh
set -u

usage() {
    printf '%s\n' "usage: adapter.sh cargo-fixture|buck-artifact [--manifest-path PATH] [--scenario pass|fail]" >&2
}

fail() {
    printf 'buck2-nextest-adapter: error: %s\n' "$1" >&2
    usage
    exit 2
}

resource_root=${BUCK_PROJECT_ROOT:-${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}}
mode=
manifest=
manifest_explicit=false
scenario=pass
artifact=${BUCK2_NEXTEST_ARTIFACT:-}
manifest_input=${BUCK2_NEXTEST_MANIFEST:-}
validator=${BUCK2_NEXTEST_VALIDATOR:-}
baseline_dir=${BUCK2_NEXTEST_BASELINE:-}
baseline_cargo=${BUCK2_NEXTEST_CARGO_BASELINE:-}
baseline_binaries=${BUCK2_NEXTEST_BINARY_BASELINE:-}
baseline_tests=${BUCK2_NEXTEST_TESTS_BASELINE:-}

while [ "$#" -gt 0 ]; do
    case "$1" in
        cargo-fixture|buck-artifact)
            [ -z "$mode" ] || fail "modes are mutually exclusive"
            mode=$1
            shift
            ;;
        --manifest-path)
            [ "$mode" != buck-artifact ] || fail "--manifest-path is not valid in buck-artifact mode"
            [ "$#" -ge 2 ] || fail "--manifest-path requires a value"
            manifest=$2
            manifest_explicit=true
            shift 2
            ;;
        --artifact)
            [ "$#" -ge 2 ] || fail "--artifact requires a value"
            [ -z "$artifact" ] || fail "artifact specified more than once"
            artifact=$2
            shift 2
            ;;
        --manifest)
            [ "$#" -ge 2 ] || fail "--manifest requires a value"
            [ -z "$manifest_input" ] || fail "manifest specified more than once"
            manifest_input=$2
            shift 2
            ;;
        --validator)
            [ "$#" -ge 2 ] || fail "--validator requires a value"
            [ -z "$validator" ] || fail "validator specified more than once"
            validator=$2
            shift 2
            ;;
        --baseline)
            [ "$#" -ge 2 ] || fail "--baseline requires a value"
            [ -z "$baseline_dir" ] || fail "baseline specified more than once"
            baseline_dir=$2
            shift 2
            ;;
        --cargo-baseline)
            [ "$#" -ge 2 ] || fail "--cargo-baseline requires a value"
            baseline_cargo=$2
            shift 2
            ;;
        --binary-baseline)
            [ "$#" -ge 2 ] || fail "--binary-baseline requires a value"
            baseline_binaries=$2
            shift 2
            ;;
        --tests-baseline)
            [ "$#" -ge 2 ] || fail "--tests-baseline requires a value"
            baseline_tests=$2
            shift 2
            ;;
        --scenario)
            [ "$#" -ge 2 ] || fail "--scenario requires a value"
            scenario=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

[ -n "$mode" ] || mode=cargo-fixture
case "$scenario" in
    pass) filterset='test(=pass_case)' ;;
    fail) filterset='test(=fail_case)' ;;
    *) fail "invalid scenario: $scenario" ;;
esac

command -v cargo >/dev/null 2>&1 || fail "cargo is not available on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 is not available on PATH"
help_output=$(cargo nextest run --help 2>&1) || fail "cargo nextest is not available"
for flag in --filterset --cargo-metadata --binaries-metadata --target-dir-remap --workspace-remap --build-dir-remap; do
    printf '%s\n' "$help_output" | grep -F -- "$flag" >/dev/null 2>&1 || fail "cargo nextest run does not expose $flag"
done
list_help=$(cargo nextest list --help 2>&1) || fail "cargo nextest list is not available"
for flag in --cargo-metadata --binaries-metadata --target-dir-remap --workspace-remap --build-dir-remap; do
    printf '%s\n' "$list_help" | grep -F -- "$flag" >/dev/null 2>&1 || fail "cargo nextest list does not expose $flag"
done

case "$mode" in
    cargo-fixture)
        [ -n "$manifest" ] || manifest=$resource_root/fixture/Cargo.toml
        [ -r "$manifest" ] && [ ! -d "$manifest" ] || fail "manifest does not exist: $manifest"
        [ -z "$artifact$manifest_input$validator$baseline_dir" ] || fail "Buck artifact inputs are not valid in cargo-fixture mode"
        ;;
    buck-artifact)
        [ -n "$artifact" ] || fail "buck-artifact requires --artifact or BUCK2_NEXTEST_ARTIFACT"
        [ -n "$manifest_input" ] || fail "buck-artifact requires --manifest or BUCK2_NEXTEST_MANIFEST"
        [ -n "$validator" ] || fail "buck-artifact requires --validator or BUCK2_NEXTEST_VALIDATOR"
        if [ -z "$baseline_cargo$baseline_binaries$baseline_tests" ] && [ -n "$baseline_dir" ]; then
            baseline_cargo=$baseline_dir/cargo-metadata.json
            baseline_binaries=$baseline_dir/binaries.json
            baseline_tests=$baseline_dir/tests.json
        fi
        [ -n "$baseline_cargo" ] && [ -n "$baseline_binaries" ] && [ -n "$baseline_tests" ] || fail "buck-artifact requires all three baseline metadata inputs"
        [ -x "$artifact" ] || fail "declared Buck artifact is not executable: $artifact"
        [ -r "$manifest_input" ] || fail "manifest does not exist: $manifest_input"
        if [ -f "$validator" ]; then
            validator_script=$validator
        else
            validator_script=$validator/nextest_artifact.py
        fi
        [ -r "$validator_script" ] || fail "validator helper is not declared: $validator"
        [ -r "$baseline_cargo" ] && [ -r "$baseline_binaries" ] && [ -r "$baseline_tests" ] || fail "baseline metadata is not declared"
        ;;
esac

if [ "$mode" = buck-artifact ] && command -v setsid >/dev/null 2>&1; then
    launcher=setsid
else
    launcher=
fi
if [ "$mode" = buck-artifact ] && [ "${BUCK2_NEXTEST_REQUIRE_PROCESS_GROUP:-0}" = 1 ] && [ -z "$launcher" ]; then
    fail "setsid is required for signal-cleanup scenarios but is unavailable"
fi

private_root=$(mktemp -d "${TMPDIR:-/tmp}/buck2-nextest-$mode.XXXXXX") || fail "could not create private root"
if [ "$mode" = buck-artifact ] && [ -e "$resource_root/fixture" ]; then
    fixture_sentinel="$private_root/fixture-access-denied"
    mv "$resource_root/fixture" "$fixture_sentinel"
    fixture_restored=false
    restore_fixture() {
        if [ "$fixture_restored" = false ]; then
            mv "$fixture_sentinel" "$resource_root/fixture"
            fixture_restored=true
        fi
    }
else
    restore_fixture() { :; }
fi
cleanup_done=false
child_pid=
child_pgid=
cleanup() {
    status=$?
    if [ "$cleanup_done" = false ]; then
        cleanup_done=true
        if [ -n "$child_pgid" ] && kill -0 "$child_pgid" 2>/dev/null; then
            kill -TERM -- "-$child_pgid" 2>/dev/null || true
            wait "$child_pid" 2>/dev/null || true
        fi
        restore_fixture
        rm -rf "$private_root"
        printf 'buck2-nextest-adapter: cleanup=once root=%s\n' "$private_root"
    fi
    trap - 0
    exit "$status"
}
trap cleanup 0 HUP INT TERM

export CARGO_NET_OFFLINE=true
export CARGO_TARGET_DIR="$private_root/target"

# Buck-artifact mode must not accidentally rediscover the checked-in fixture.
if [ "$mode" = buck-artifact ]; then
    export CARGO_MANIFEST_DIR="$private_root/workspace"
    export CARGO_HOME="$private_root/cargo-home"
    export BUCK2_NEXTEST_REAL_CARGO=$(command -v cargo)
    export BUCK2_NEXTEST_DISPATCH_LOG="$private_root/dispatch.log"
    export BUCK2_NEXTEST_NESTED_CARGO_LOG="$private_root/nested-cargo.log"
    export BUCK2_NEXTEST_COMPILER_LOG="$private_root/compiler.log"
    export BUCK2_NEXTEST_DISPATCH_ALLOWED=1
fi

if [ "$mode" = cargo-fixture ]; then
    printf 'buck2-nextest-adapter: mode=cargo-fixture scenario=%s manifest=%s\n' "$scenario" "$manifest"
    printf 'buck2-nextest-adapter: exec cargo nextest run --manifest-path %s --locked --filterset %s\n' "$manifest" "$filterset"
    cargo nextest run --manifest-path "$manifest" --locked --filterset "$filterset"
    exit $?
fi

mkdir -p "$private_root/workspace/src" "$private_root/target/debug/deps"
if [ "$mode" = buck-artifact ]; then
    export PATH="$private_root:$PATH"
fi
cp "$manifest_input" "$private_root/manifest.json"
cp "$validator_script" "$private_root/nextest_artifact.py"
cp "$validator/../cargo_source_denial.sh" "$private_root/cargo" 2>/dev/null || cp tools/cargo_source_denial.sh "$private_root/cargo"
cp "$validator/../cargo_source_denial.sh" "$private_root/rustc" 2>/dev/null || cp tools/cargo_source_denial.sh "$private_root/rustc"
chmod +x "$private_root/cargo" "$private_root/rustc"
cp "$baseline_cargo" "$private_root/baseline-cargo.json"
cp "$baseline_binaries" "$private_root/baseline-binaries.json"
cp "$baseline_tests" "$private_root/baseline-tests.json"
python3 "$private_root/nextest_artifact.py" validate-manifest --manifest "$private_root/manifest.json" --root "$private_root" --allow-missing
executable_rel=$(python3 -c 'import json; print(json.load(open("'$private_root'/manifest.json"))["paths"]["executable"])')
working_rel=$(python3 -c 'import json; print(json.load(open("'$private_root'/manifest.json"))["paths"]["working_directory"])')
executable_stage="$private_root/$executable_rel"
working_stage="$private_root/$working_rel"
mkdir -p "$(dirname "$executable_stage")" "$working_stage"
cp "$artifact" "$executable_stage"
chmod +x "$executable_stage"
python3 "$private_root/nextest_artifact.py" validate-manifest --manifest "$private_root/manifest.json" --root "$private_root"
python3 "$private_root/nextest_artifact.py" synthesize --cargo-baseline "$private_root/baseline-cargo.json" --binary-baseline "$private_root/baseline-binaries.json" --tests-baseline "$private_root/baseline-tests.json" --target-dir "$private_root/target" --workspace "$private_root/workspace" --output-dir "$private_root/meta" --manifest "$private_root/manifest.json" --manifest-root "$private_root"
cp "$executable_stage" "$private_root/target/debug/deps/buck2_nextest_rust_test"
chmod +x "$private_root/target/debug/deps/buck2_nextest_rust_test"

digest_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}
buck_digest=$(digest_file "$artifact")
staged_digest=$(digest_file "$executable_stage")
[ "$buck_digest" = "$staged_digest" ] || fail "declared and staged artifact digests differ"
printf 'buck2-nextest-adapter: mode=buck-artifact scenario=%s\n' "$scenario"
printf 'buck2-nextest-adapter: buck-output=%s digest=%s\n' "$artifact" "$buck_digest"
printf 'buck2-nextest-adapter: staged-executable=%s digest=%s\n' "$executable_stage" "$staged_digest"
printf 'buck2-nextest-adapter: manifest-root=%s metadata=%s\n' "$private_root" "$private_root/meta"

run_nextest() {
    command cargo nextest "$@" --cargo-metadata "$private_root/meta/cargo-metadata.json" --binaries-metadata "$private_root/meta/binaries-metadata.json" --target-dir-remap "$private_root/target" --build-dir-remap "$private_root/target" --workspace-remap "$private_root/workspace"
}
printf '[package]\nname = "buck2-nextest-buck-artifact"\nversion = "0.1.0"\nedition = "2021"\n' > "$private_root/workspace/Cargo.toml"
export BUCK2_NEXTEST_RUNTIME=declared
cd "$working_stage"
printf 'buck2-nextest-adapter: exec cargo nextest list --message-format json (supplied metadata)\n'
run_nextest list --message-format json >"$private_root/list.json"
if [ ! -s "$private_root/dispatch.log" ]; then
    fail "nextest dispatch sentinel did not record top-level cargo nextest"
fi
[ ! -s "$private_root/nested-cargo.log" ] || fail "nested Cargo operation was attempted"
[ ! -s "$private_root/compiler.log" ] || fail "compiler invocation was attempted"
grep -F 'buck2_nextest_rust_test' "$private_root/list.json" >/dev/null 2>&1 || fail "synthetic binary was not listed"
grep -F 'pass_case' "$private_root/list.json" >/dev/null 2>&1 || fail "pass_case was not listed"
grep -F 'fail_case' "$private_root/list.json" >/dev/null 2>&1 || fail "fail_case was not listed"
printf 'buck2-nextest-adapter: exec cargo nextest run --filterset %s (supplied metadata)\n' "$filterset"
if [ -n "$launcher" ]; then
    "$launcher" sh -c 'exec cargo nextest run --message-format human --filterset "$1" --cargo-metadata "$2" --binaries-metadata "$3" --target-dir-remap "$4" --build-dir-remap "$4" --workspace-remap "$5"' sh "$filterset" "$private_root/meta/cargo-metadata.json" "$private_root/meta/binaries-metadata.json" "$private_root/target" "$private_root/workspace" &
else
    BUCK2_NEXTEST_DISPATCH_ALLOWED=1 cargo nextest run --message-format human --filterset "$filterset" --cargo-metadata "$private_root/meta/cargo-metadata.json" --binaries-metadata "$private_root/meta/binaries-metadata.json" --target-dir-remap "$private_root/target" --build-dir-remap "$private_root/target" --workspace-remap "$private_root/workspace" &
fi
child_pid=$!
if [ -n "$launcher" ]; then
    child_pgid=$child_pid
else
    child_pgid=
fi
wait "$child_pid"
exit $?
