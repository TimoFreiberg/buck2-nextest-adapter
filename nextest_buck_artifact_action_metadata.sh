#!/bin/sh
set -eu
root=${BUCK_PROJECT_ROOT:-$(pwd -P)}
buck=${BUCK2:-buck2}
help=$($buck build --help 2>&1 || true)
if ! printf '%s\n' "$help" | grep -E -i 'force|no-cache|fresh' >/dev/null; then
    printf '%s\n' 'action-metadata=observability-gap reason=fresh-execution-capability-unavailable'
    exit 0
fi
run_root=$(mktemp -d "${TMPDIR:-/tmp}/nextest-action-metadata.XXXXXX")
trap 'rm -rf "$run_root"' EXIT
isolation="$run_root/isolation"
mkdir "$isolation"
out="$run_root/build.out"
set +e
"$buck" --isolation-dir "$isolation" build //:nextest_buck_artifact_junit >"$out" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] || { cat "$out" >&2; exit 1; }
[ "$(grep -c '^action-metadata=validated$' "$out")" -eq 1 ]
printf '%s\n' 'action metadata check: passed'
