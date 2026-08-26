#!/bin/sh
set -eu

project=${BUCK_PROJECT_ROOT:-$(CDPATH= cd -- "$(dirname "$0")" && pwd)}
cd "$project"
./executor/proto/regenerate.sh --check
