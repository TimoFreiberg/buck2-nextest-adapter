#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
check=false
if [ "${1:-}" = "--check" ]; then
    check=true
elif [ "$#" -ne 0 ]; then
    printf '%s\n' 'usage: executor/proto/regenerate.sh [--check]' >&2
    exit 2
fi

out=$(mktemp -d "${TMPDIR:-/tmp}/nextest-proto.XXXXXX")
trap 'rm -rf "$out"' EXIT HUP INT TERM
(
    cd "$root/codegen"
    cargo run --locked --quiet -- "$out"
)

if "$check"; then
    diff -ru --no-dereference "$root/src/proto/gen" "$out"
else
    rm -f "$root/src/proto/gen"/*.rs
    cp "$out"/*.rs "$root/src/proto/gen/"
fi
