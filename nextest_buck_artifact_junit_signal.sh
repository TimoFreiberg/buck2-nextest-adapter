#!/bin/sh
set -eu

if ! command -v setsid >/dev/null 2>&1; then
    printf '%s\n' 'declared JUnit signal cleanup: BLOCKED (setsid/process groups unavailable)' >&2
    exit 0
fi
printf '%s\n' 'declared JUnit signal cleanup: BLOCKED (Buck action signal harness is deferred)' >&2
exit 0
