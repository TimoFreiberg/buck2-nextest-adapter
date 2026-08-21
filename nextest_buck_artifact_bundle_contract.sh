#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
toolchain=$root/toolchains/nextest.bzl
[ -f "$toolchain" ] || toolchain=${BUCK_PROJECT_ROOT:-.}/toolchains/nextest.bzl
grep -F 'bundle_version = 1' "$root/../toolchains/BUCK" "$root/toolchains/BUCK" >/dev/null 2>&1 || grep -F 'bundle_version' "$toolchain" >/dev/null
grep -F 'NextestBuckBundleResourceInfo' "$toolchain" >/dev/null
grep -F 'duplicate bundle resource path' "$toolchain" >/dev/null
grep -F 'normalized relative POSIX' "$toolchain" >/dev/null
grep -F 'bundle_platform' "$toolchain" >/dev/null
printf '%s\n' 'nextest bundle contract: passed'
