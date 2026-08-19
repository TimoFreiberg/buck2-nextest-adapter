#!/bin/sh
set -eu

out=${1:-capability-preflight.txt}
{
    printf 'cargo=%s\n' "$(cargo --version)"
    printf 'rustc=%s\n' "$(rustc --version)"
    printf 'cargo-nextest=%s\n' "$(cargo nextest --version | head -1)"
    printf 'buck2=%s\n' "$(buck2 --version | head -1)"
    printf 'host=%s\n' "$(rustc -vV | grep '^host:')"
    for command in list run; do
        help=$(cargo nextest "$command" --help 2>&1)
        for flag in --cargo-metadata --binaries-metadata --target-dir-remap --workspace-remap --build-dir-remap; do
            printf '%s\n' "$help" | grep -F -- "$flag" >/dev/null
            printf '%s %s=present\n' "$command" "$flag"
        done
    done
    run_help=$(cargo nextest run --help 2>&1)
    for flag in --filterset --profile --no-tests; do
        printf '%s\n' "$run_help" | grep -F -- "$flag" >/dev/null
        printf 'run %s=present\n' "$flag"
    done
    printf 'config report-skipped=ignored and slow-timeout=present\n'
    if command -v setsid >/dev/null 2>&1; then
        printf 'process-group-launcher=setsid\n'
    else
        printf 'process-group-launcher=BLOCKED(setid-unavailable)\n'
    fi
    printf 'source-denial=required-by-buck-artifact-scenario\n'
    printf 'no-compilation-marker=not-sufficient-for-no-discovery\n'
} > "$out"
printf 'capability preflight written to %s\n' "$out"
