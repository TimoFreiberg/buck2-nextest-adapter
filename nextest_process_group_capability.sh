#!/bin/sh
set -eu
if command -v setsid >/dev/null 2>&1; then
    printf '%s\n' 'process-group=available'
    exit 0
fi
printf '%s\n' 'process-group=unavailable' >&2
exit 1
