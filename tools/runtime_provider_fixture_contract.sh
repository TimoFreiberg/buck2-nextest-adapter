#!/bin/sh
set -eu
fixture=${1:?missing fixture executable}
output=$($fixture --exact provider_runtime_resource_case --nocapture 2>&1)
printf '%s\n' "$output" | grep -F 'buck2-nextest runtime resource=ok' >/dev/null
printf '%s\n' 'runtime provider fixture contract: passed'
