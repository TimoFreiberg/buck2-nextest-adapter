#!/bin/sh
set -eu
if ! command -v setsid >/dev/null 2>&1; then
    printf '%s\n' 'adapter missing-setsid validation: BLOCKED (setsid unavailable)' >&2
    exit 0
fi
printf '%s\n' 'adapter process-group prerequisite: setsid available; positive coverage is in nextest_buck_artifact_junit_signal'
