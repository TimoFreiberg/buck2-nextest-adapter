#!/bin/sh
set -eu
root=${BUCK_PROJECT_ROOT:-$(cd "$(dirname "$0")" && pwd -P)}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/adapter-relocated-record-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
records=$tmp/records
mkdir "$records"
export ADAPTER_RELOCATED_RECORD_DIR="$records"
export ADAPTER_RELOCATED_RECORD_HELPER="$root/tools/nextest_relocated_records.py"
export ADAPTER_RELOCATED_RECORD_PREFIX="$records/record"
export BUCK_PROJECT_ROOT="$root"
PATH=/usr/bin:/bin /usr/bin/python3 "$ADAPTER_RELOCATED_RECORD_HELPER" write-launcher "$root/tools/nextest_python_launcher.sh" setup
PATH=/usr/bin:/bin /usr/bin/python3 "$ADAPTER_RELOCATED_RECORD_HELPER" write-fixture "$root/tools/nextest_cargo_nextest_v1.py"
identity=$tmp/identity
observability=$tmp/observability
printf 'python_buck_output_path=%s\npython_buck_output_digest=%s\nnextest_buck_output_path=%s\nnextest_buck_output_digest=%s\n' \
  "$root/tools/nextest_python_launcher.sh" "$(sha256sum "$root/tools/nextest_python_launcher.sh" | awk '{print $1}')" \
  "$root/tools/nextest_cargo_nextest_v1.py" "$(sha256sum "$root/tools/nextest_cargo_nextest_v1.py" | awk '{print $1}')" >"$identity"
set +e
/usr/bin/python3 "$ADAPTER_RELOCATED_RECORD_HELPER" merge "$records" "$identity" "$observability"
status=$?
set -e
[ "$status" -eq 0 ] || exit 1
cp "$(find "$records" -name '*.record' | head -1)" "$records/replay.record"
/usr/bin/python3 "$ADAPTER_RELOCATED_RECORD_HELPER" merge "$records" "$identity" "$observability"
# A conflicting duplicate sequence must be rejected.
first=$(find "$records" -name '*.record' | head -1)
sed 's/^cwd=.*/cwd=conflicting-cwd/' "$first" >"$records/conflict.record"
set +e
/usr/bin/python3 "$ADAPTER_RELOCATED_RECORD_HELPER" merge "$records" "$identity" "$observability" 2>"$tmp/error"
status=$?
set -e
[ "$status" -ne 0 ]
grep -F 'duplicate process phase sequence' "$tmp/error" >/dev/null
printf '%s\n' 'adapter relocated record merge test: passed'
