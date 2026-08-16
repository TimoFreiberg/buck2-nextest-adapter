#!/bin/sh
set -eu

artifact=${1:?usage: emit_artifact_manifest.sh ARTIFACT OUTPUT}
output=${2:?usage: emit_artifact_manifest.sh ARTIFACT OUTPUT}
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 "$root/tools/nextest_artifact.py" emit-manifest --artifact "$artifact" --output "$output"
