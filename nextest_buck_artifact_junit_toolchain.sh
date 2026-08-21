#!/bin/sh
set -eu

output=${1:?declared JUnit output argument is required}
[ -f "$output" ]
[ -z "${BUCK2_NEXTEST_DISPATCH_LOG:-}" ] || exit 1
toolchain_bzl=${BUCK_PROJECT_ROOT:-.}/toolchains/nextest.bzl
[ -f "$toolchain_bzl" ] || toolchain_bzl=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}/toolchains/nextest.bzl
grep -F 'attrs.exec_dep' "$toolchain_bzl"
grep -F 'providers = [DefaultInfo, RunInfo]' "$toolchain_bzl"
grep -F 'default_outputs' "$toolchain_bzl"
grep -F 'RunInfo(args = cmd_args' "$toolchain_bzl"
grep -F 'NextestBuckBundleResourceInfo' "$toolchain_bzl"
grep -F 'bundle_version' "$toolchain_bzl"
grep -F 'bundle_environment' "$toolchain_bzl"
grep -F 'bundle_platform' "$toolchain_bzl"
python3 - "$output" <<'PY'
import sys
import xml.etree.ElementTree as ET
assert [x.attrib["name"] for x in ET.parse(sys.argv[1]).getroot().iter("testcase")] == ["pass_case"]
PY
printf '%s\n' "declared JUnit toolchain passed: local-only"
