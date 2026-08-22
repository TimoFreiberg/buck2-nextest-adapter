#!/bin/sh
set -eu

TARGET="$HOME/Library/Caches/pantoken-cargo-target"

if [ -d "$TARGET" ]; then
    printf 'Deleting %s\n' "$TARGET"
    rm -rf -- "$TARGET"
else
    printf 'Not found: %s\n' "$TARGET"
fi
