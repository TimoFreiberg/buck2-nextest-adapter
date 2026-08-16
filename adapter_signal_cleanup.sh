#!/bin/sh
set -eu

if ! command -v setsid >/dev/null 2>&1; then
    printf '%s\n' 'adapter signal cleanup: BLOCKED (setsid is unavailable on this host)' >&2
    exit 0
fi
export BUCK2_NEXTEST_REQUIRE_PROCESS_GROUP=1

printf '%s\n' 'adapter signal cleanup: launcher available; dedicated INT/TERM scenario required'
