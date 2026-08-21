#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
rule=${1:-$root/nextest.bzl}
[ -f "$rule" ]
for pair in \
    '"--profile", ctx.attrs.profile' \
    '"--filter", ctx.attrs.filter' \
    '"--no-tests", ctx.attrs.no_tests' \
    '"--report-skipped", ctx.attrs.report_skipped' \
    '"--timeout-seconds", str(ctx.attrs.timeout_seconds)'; do
    grep -F "$pair" "$rule" >/dev/null
done
grep -F 'local_only = True' "$rule" >/dev/null
grep -F 'allow_cache_upload = False' "$rule" >/dev/null
grep -F 'bundle-json' "$rule" >/dev/null
grep -F 'bundle-resources' "$rule" >/dev/null
grep -F 'local-fixture-v1' "${BUCK_PROJECT_ROOT:-.}/toolchains/BUCK" >/dev/null
printf '%s\n' 'nextest rule contract: passed'
