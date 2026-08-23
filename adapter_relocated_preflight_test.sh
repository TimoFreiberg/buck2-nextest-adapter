#!/bin/sh
set -eu
root=${BUCK_PROJECT_ROOT:-$(cd "$(dirname "$0")" && pwd -P)}
preflight="$root/adapter_relocated_preflight.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/adapter-preflight-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/bin"
mkdir "$fixture"
for command_name in sh env mkdir cp chmod mktemp dirname rm grep sed cat basename tr wc bash realpath awk cut tail ln python3 sha256sum buck2; do
    path=$(command -v "$command_name")
    ln -s "$path" "$fixture/$command_name"
done
interpreter="$tmp/python3-fixed"
cp /usr/bin/python3 "$interpreter"
chmod +x "$interpreter"

run_case() {
    omitted=$1
    set +e
    output=$(PATH="$fixture" BUCK2=buck2 ADAPTER_RELOCATED_PREFLIGHT_TEST_INTERPRETER="$interpreter" /bin/sh "$preflight" "$root" 2>&1)
    status=$?
    set -e
    [ "$status" -eq 1 ] || { printf '%s\n' "$output" >&2; exit 1; }
    printf '%s\n' "$output" | PATH=/usr/bin:/bin grep -Fx "relocation preflight: missing command=$omitted" >/dev/null
    [ "$(PATH=/usr/bin:/bin printf '%s\n' "$output" | PATH=/usr/bin:/bin grep -Fc "relocation preflight: missing command=$omitted")" -eq 1 ]
    ! PATH=/usr/bin:/bin grep -F 'BUCK2_RELOCATION_TEST_LOG' <<EOF
$output
EOF
}

# Check every ordinary command independently.
for command_name in sh env mkdir cp chmod mktemp dirname rm grep sed cat basename tr wc bash realpath awk cut tail ln python3; do
    rm -f "$fixture/$command_name"
    run_case "$command_name"
    ln -s "$(command -v "$command_name")" "$fixture/$command_name"
done

rm -f "$fixture/sha256sum"
rm -f "$fixture/shasum"
set +e
output=$(PATH="$fixture" BUCK2=buck2 ADAPTER_RELOCATED_PREFLIGHT_TEST_INTERPRETER="$interpreter" /bin/sh "$preflight" "$root" 2>&1)
status=$?
set -e
[ "$status" -eq 1 ]
printf '%s\n' "$output" | grep -Fx 'relocation preflight: missing command=sha256sum-or-shasum' >/dev/null
ln -s "$(command -v sha256sum)" "$fixture/sha256sum"

rm -f "$fixture/python3"
set +e
output=$(PATH="$fixture" BUCK2=buck2 ADAPTER_RELOCATED_PREFLIGHT_TEST_INTERPRETER="$interpreter" /bin/sh "$preflight" "$root" 2>&1)
status=$?
set -e
[ "$status" -eq 1 ]
printf '%s\n' "$output" | grep -Fx 'relocation preflight: missing command=python3' >/dev/null
ln -s "$(command -v python3)" "$fixture/python3"

rm -f "$interpreter"
set +e
output=$(PATH="$fixture" BUCK2=buck2 ADAPTER_RELOCATED_PREFLIGHT_TEST_INTERPRETER="$interpreter" /bin/sh "$preflight" "$root" 2>&1)
status=$?
set -e
[ "$status" -eq 1 ]
printf '%s\n' "$output" | grep -Fx 'relocation preflight: missing interpreter=/usr/bin/python3' >/dev/null

# Multiple omissions are reported together, with no pass marker.
cp /usr/bin/python3 "$interpreter"
rm -f "$fixture/grep" "$fixture/cut" "$fixture/tail"
set +e
output=$(PATH="$fixture" BUCK2=buck2 ADAPTER_RELOCATED_PREFLIGHT_TEST_INTERPRETER="$interpreter" /bin/sh "$preflight" "$root" 2>&1)
status=$?
set -e
[ "$status" -eq 1 ]
for command_name in grep cut tail; do printf '%s\n' "$output" | PATH=/usr/bin:/bin grep -Fx "relocation preflight: missing command=$command_name" >/dev/null; done
! printf '%s\n' "$output" | PATH=/usr/bin:/bin grep -F 'relocation preflight: missing interpreter=/usr/bin/python3' >/dev/null
! printf '%s\n' "$output" | PATH=/usr/bin:/bin grep -F 'passed' >/dev/null
printf '%s\n' 'adapter relocated preflight test: passed'
