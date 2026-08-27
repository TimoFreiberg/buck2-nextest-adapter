#!/bin/sh
set -eu
runner=${1:?missing contract runner}
alpha=${2:?missing alpha executable}
beta=${3:?missing beta executable}
manifest=$(mktemp)
trap 'rm -f "$manifest"' EXIT
cat >"$manifest" <<EOF
{"schema_version":2,"records":[{"package_identity":"demo-package","owner_label":"//:demo_tests","binary_identity":"alpha","display_name":"same-display-name","target_kind":"test","executable":{"source":"buck2_nextest_rust_test","destination":"work/bin/alpha","kind":"regular_file"},"runtime":[],"generated_outputs":[],"cwd":"work","platform":"local-fixture-v1"},{"package_identity":"demo-package","owner_label":"//:demo_tests","binary_identity":"beta","display_name":"same-display-name","target_kind":"test","executable":{"source":"buck2_nextest_rust_test_beta","destination":"work/bin/beta","kind":"regular_file"},"runtime":[],"generated_outputs":[],"cwd":"work","platform":"local-fixture-v1"}]}
EOF
output=$($runner --manifest "$manifest" --record-count 2 --declared-input "$alpha" --declared-input "$beta")
printf '%s\n' "$output" | grep -F 'provider=NextestBuckTestBinaryInfo' >/dev/null
printf '%s\n' "$output" | grep -F 'records=2' >/dev/null
printf '%s\n' "$output" | grep -F 'b2n1:p=demo-package;o=%2F%2F%3Ademo_tests;b=alpha' >/dev/null
printf '%s\n' "$output" | grep -F 'b2n1:p=demo-package;o=%2F%2F%3Ademo_tests;b=beta' >/dev/null
