#!/bin/sh
set -eu

executor=${1:?executor path required}
case "$executor" in
    /*) ;;
    *) printf '%s\n' 'executor path must be absolute' >&2; exit 1 ;;
esac

# The real FD/TCP lifecycle wrappers validate the complete child argv. This
# process check only verifies that the built binary rejects a malformed outer
# invocation before attempting to consume transport descriptors.
set +e
"$executor" --buck-trace-id trace --executor-fd 3 --orchestrator-fd 4 -- ignored --buck-test-info ignored --timeout nope --junit-dir /tmp/private/junit >/tmp/executor-argv.out 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
grep -F 'unsupported Buck2 test executor invocation' /tmp/executor-argv.out >/dev/null
rm -f /tmp/executor-argv.out
printf '%s\n' 'executor argv contract: passed'
