#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
artifact=$1
manifest=$2
validator=$3
cargo_baseline=$4
binary_baseline=$5
tests_baseline=$6
tmp=$(mktemp -d "./.buck2-nextest-real.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
real_cargo=$(command -v cargo || true)
[ -n "$real_cargo" ] || { echo 'real cargo is unavailable' >&2; exit 1; }
events=$tmp/events.jsonl
shim=$tmp/cargo
cat >"$shim" <<'SHIM'
#!/bin/sh
set -eu
event_log=${BUCK2_NEXTEST_REAL_DISPATCH_EVENTS:?}
real=${BUCK2_NEXTEST_REAL_CARGO_TARGET:?}
case "$*" in
    'nextest run --help') event=probe-run-help ;;
    'nextest list --help') event=probe-list-help ;;
    'nextest list '*) event=dispatch-list ;;
    'nextest run '*) event=dispatch-run ;;
    *) echo "unexpected cargo invocation: $*" >&2; exit 91 ;;
esac
if [ "$event" = dispatch-list ] || [ "$event" = dispatch-run ]; then
    printf 'top-level cargo nextest dispatch: %s\n' "$*" >>"${BUCK2_NEXTEST_DISPATCH_LOG:?}"
fi
python3 - "$event_log" "$event" "$real" "$@" <<'PY'
import json
import sys
from pathlib import Path
path, event, real, *argv = sys.argv[1:]
with Path(path).open("a", encoding="utf-8") as stream:
    json.dump({"event": event, "argv": argv}, stream)
    stream.write("\n")
PY
exec "$real" "$@"
SHIM
chmod +x "$shim"
set +e
BUCK2_NEXTEST_REAL_DISPATCH_EVENTS="$events" BUCK2_NEXTEST_REAL_CARGO_TARGET="$real_cargo" \
PATH="$tmp:$PATH" BUCK2_NEXTEST_DISPATCH_LOG="$tmp/dispatch.log" \
BUCK2_NEXTEST_PROBE_LOG="$tmp/probe.log" BUCK2_NEXTEST_NESTED_CARGO_LOG="$tmp/nested.log" \
BUCK2_NEXTEST_COMPILER_LOG="$tmp/compiler.log" \
"$root/adapter.sh" buck-artifact --artifact "$artifact" --manifest "$manifest" --validator "$validator" \
    --cargo-baseline "$cargo_baseline" --binary-baseline "$binary_baseline" --tests-baseline "$tests_baseline" \
    --junit-report "$tmp/report.xml" --profile ci --filter 'test(=pass_case)' --no-tests auto \
    --report-skipped default --timeout-seconds 0 >"$tmp/out" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] || { cat "$tmp/out" >&2; exit 1; }
python3 - "$events" <<'PY'
import json
import sys
from pathlib import Path
records = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert len(records) == 4, records
assert [record["event"] for record in records] == ["probe-run-help", "probe-list-help", "dispatch-list", "dispatch-run"], records
for record in records:
    assert set(record) == {"event", "argv"}, record
    assert isinstance(record["argv"], list) and record["argv"], record
PY
python3 - "$tmp/report.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = root.findall('.//testcase')
assert [case.get('name') for case in cases] == ['pass_case'], cases
assert not root.findall('.//adapter-summary')
PY
[ "$(grep -c 'cleanup=once' "$tmp/out")" -eq 1 ]
private_root=$(sed -n 's/.*cleanup=once root=//p' "$tmp/out")
[ -n "$private_root" ] && [ ! -e "$private_root" ]
[ ! -s "$tmp/nested.log" ] && [ ! -s "$tmp/compiler.log" ]
printf '%s\n' 'buck artifact real dispatch: passed'
