#!/bin/sh
set -eu

if [ "${1:-}" = nextest ]; then
    case "$*" in
        'nextest run --help'|'nextest list --help') exec "${BUCK2_NEXTEST_REAL_CARGO:?}" "$@" ;;
    esac
    printf 'top-level cargo nextest dispatch\n' >>"${BUCK2_NEXTEST_DISPATCH_LOG:?}"
    exec "${BUCK2_NEXTEST_REAL_CARGO:?}" "$@"
fi
if [ -n "${BUCK2_NEXTEST_COMPILER_LOG:-}" ]; then
    printf 'compiler invocation denied: %s\n' "$*" >>"$BUCK2_NEXTEST_COMPILER_LOG"
else
    printf 'nested cargo operation denied: %s\n' "$*" >>"${BUCK2_NEXTEST_NESTED_CARGO_LOG:?}"
fi
exit 97
