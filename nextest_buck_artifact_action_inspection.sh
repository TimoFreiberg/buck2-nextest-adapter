#!/bin/sh
set -eu
buck=${1:?Buck2 binary is required}
inspection=${2:?inspection helper is required}
project=${BUCK_PROJECT_ROOT:-$(pwd -P)}
python3 "$inspection" "$buck" "$project"
