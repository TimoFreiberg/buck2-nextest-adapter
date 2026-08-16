#!/bin/sh
set -u

usage() {
    printf '%s\n' "usage: adapter.sh [--manifest-path PATH] [--scenario pass|fail]" >&2
}

fail() {
    printf 'buck2-nextest-adapter: error: %s\n' "$1" >&2
    usage
    exit 2
}

resource_root=${BUCK_PROJECT_ROOT:-${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}}
manifest=$resource_root/fixture/Cargo.toml
manifest_explicit=false
scenario=pass

while [ "$#" -gt 0 ]; do
    case "$1" in
        --manifest-path)
            [ "$#" -ge 2 ] || fail "--manifest-path requires a value"
            manifest=$2
            manifest_explicit=true
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

case "$scenario" in
    pass) filterset='test(=pass_case)' ;;
    fail) filterset='test(=fail_case)' ;;
    *) fail "invalid scenario: $scenario" ;;
esac

[ -r "$manifest" ] && [ ! -d "$manifest" ] || fail "manifest does not exist: $manifest"
command -v cargo >/dev/null 2>&1 || fail "cargo is not available on PATH"

help_output=$(cargo nextest run --help 2>&1) || {
    printf '%s\n' "buck2-nextest-adapter: error: cargo nextest is not available" >&2
    exit 1
}
printf '%s\n' "$help_output" | grep -F -- '--filterset' >/dev/null 2>&1 || {
    printf '%s\n' "buck2-nextest-adapter: error: cargo nextest does not expose --filterset" >&2
    exit 1
}

target_dir=$(mktemp -d "${TMPDIR:-/tmp}/buck2-nextest-target.XXXXXX") || {
    printf '%s\n' 'buck2-nextest-adapter: error: could not create temporary target directory' >&2
    exit 1
}
cleanup() {
    rm -rf "$target_dir"
}
trap cleanup 0 HUP INT TERM

export CARGO_NET_OFFLINE=true
export CARGO_TARGET_DIR=$target_dir

printf 'buck2-nextest-adapter: scenario=%s manifest=%s\n' "$scenario" "$manifest"
printf 'buck2-nextest-adapter: exec cargo nextest run --manifest-path %s --locked --filterset %s\n' "$manifest" "$filterset"
cargo nextest run --manifest-path "$manifest" --locked --filterset "$filterset"
status=$?
exit "$status"
