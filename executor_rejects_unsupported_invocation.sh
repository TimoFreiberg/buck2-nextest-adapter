#!/bin/sh
set -eu

executor=${1:?executor path required}
base='--buck-trace-id trace --executor-fd 3 --orchestrator-fd 4 -- ignored --buck-test-info ignored --junit-dir /tmp/private/junit'
set +e
output=$(sh -c "exec \"$executor\" $base --unknown" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ]
printf '%s\n' "$output" | grep -F 'supported Buck2 version' >/dev/null
printf '%s\n' 'executor unsupported invocation: passed'
