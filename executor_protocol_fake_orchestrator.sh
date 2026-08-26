#!/bin/sh
set -eu

# The generated protocol and state-machine tests are intentionally executed by
# Cargo/Buck rather than by a second nested Buck invocation.
project=${BUCK_PROJECT_ROOT:-$(CDPATH= cd -- "$(dirname "$0")" && pwd)}
cd "$project/executor"
cargo test --locked --all-targets
