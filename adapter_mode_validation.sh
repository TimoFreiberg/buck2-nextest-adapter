#!/bin/sh
set -eu

set +e
resource_root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
adapter=$resource_root/adapter.sh
"$adapter" --scenario invalid >/tmp/adapter-invalid.out 2>&1
s1=$?
"$adapter" buck-artifact --scenario pass >/tmp/adapter-missing.out 2>&1
s2=$?
"$adapter" cargo-fixture buck-artifact >/tmp/adapter-mixed.out 2>&1
s3=$?
"$adapter" buck-artifact --manifest-path "$resource_root/fixture/Cargo.toml" >/tmp/adapter-fixture-option.out 2>&1
s4=$?
set -e
[ "$s1" -ne 0 ]
[ "$s2" -ne 0 ]
[ "$s3" -ne 0 ]
[ "$s4" -ne 0 ]
! grep -F 'exec cargo nextest' /tmp/adapter-invalid.out /tmp/adapter-missing.out /tmp/adapter-mixed.out /tmp/adapter-fixture-option.out
printf '%s\n' 'adapter mode validation: passed'
