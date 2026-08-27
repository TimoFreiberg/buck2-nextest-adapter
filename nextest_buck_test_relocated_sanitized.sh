#!/bin/sh
# Repository-level schema-v2 native-materialization and relocation assurance.
set -eu

project=${BUCK_PROJECT_ROOT:-$(CDPATH= cd -- "$(dirname "$0")" && pwd -P)}
buck=${BUCK2:-buck2}
case "$(uname -s)" in
    Darwin) temp_root=/private/tmp ;;
    Linux) temp_root=/tmp ;;
    *) printf '%s\n' 'schema-v2 relocation: unsupported host OS' >&2; exit 2 ;;
esac
case "$(uname -s):$(uname -m)" in
    Darwin:x86_64|Darwin:arm64|Linux:x86_64|Linux:amd64|Linux:aarch64|Linux:arm64) ;;
    *) printf '%s\n' 'schema-v2 relocation: unsupported host architecture' >&2; exit 2 ;;
esac
"$buck" test --help 2>&1 | grep -F -- '--event-log' >/dev/null || { printf '%s\n' 'schema-v2 relocation: missing event-log capability' >&2; exit 2; }
"$buck" log what-ran --help 2>&1 | grep -F -- '--filter-category' >/dev/null || { printf '%s\n' 'schema-v2 relocation: missing what-ran capability' >&2; exit 2; }

checksum() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'
    fi
}

root=$(mktemp -d "$temp_root/buck2-nextest-v2-relocated.XXXXXX")
cleanup_status=0
cleanup() {
    status=$?
    if [ "$status" -ne 0 ] || [ "$cleanup_status" -ne 0 ]; then
        printf 'schema-v2 relocation: retained diagnostics at %s\n' "$root" >&2
        [ -f "$root/output" ] && cat "$root/output" >&2 || true
        [ -f "$root/what-ran" ] && cat "$root/what-ran" >&2 || true
    else
        rm -rf "$root" || cleanup_status=$?
    fi
    if [ "$cleanup_status" -ne 0 ]; then exit "$cleanup_status"; fi
    exit "$status"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$root/caller/junit" "$root/observation"

executor=$($buck build --show-output //:nextest_v2_executor | tail -1 | cut -d' ' -f2)
case "$executor" in /*) ;; *) executor="$project/$executor" ;; esac
executor=$(CDPATH= cd -- "$(dirname "$executor")" && pwd -P)/$(basename "$executor")

isolation="nextest-v2-relocated-$$"
build_output=$($buck --isolation-dir "$isolation" build --no-remote-cache --show-output //:nextest_buck_test_binary_runtime_positive 2>&1)
executable=$(printf '%s\n' "$build_output" | awk '/^root\/\/.*[[:space:]][^[:space:]]+$/ { value=$NF } END { if (value == "") exit 1; print value }') || {
    printf '%s\n' "$build_output" >&2
    exit 1
}
case "$executable" in /*) ;; *) executable="$project/$executable" ;; esac
executable=$(CDPATH= cd -- "$(dirname "$executable")" && pwd -P)/$(basename "$executable")
database="${executable}.resources.json"
resource=$(python3 - "$database" "$executable" <<'PY'
import json
from pathlib import Path
import sys
value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
relative = value.get("nextest-generated-rust-runtime-resource.txt")
if not isinstance(relative, str):
    raise SystemExit("resource database has no generated resource entry")
print((Path(sys.argv[2]).parent / relative).resolve())
PY
)
for path in "$executable" "$database" "$resource"; do
    [ -f "$path" ] && [ ! -L "$path" ] || { printf 'schema-v2 relocation: missing regular artifact %s\n' "$path" >&2; exit 1; }
done
[ -x "$executable" ] || { printf '%s\n' 'schema-v2 relocation: executable is not executable' >&2; exit 1; }
case "$executable" in
    "$project"/buck-out/*) ;;
    *) printf 'schema-v2 relocation: executable escaped Buck output: %s\n' "$executable" >&2; exit 1 ;;
esac
before=$(mktemp "$root/native-before.XXXXXX")
after=$(mktemp "$root/native-after.XXXXXX")
(CDPATH= cd -- "$(dirname "$executable")" && find . -mindepth 1 -maxdepth 1 -print | sort) >"$before"
exe_digest=$(checksum "$executable")
database_digest=$(checksum "$database")
resource_digest=$(checksum "$resource")

set +e
"$buck" --isolation-dir "$isolation" test --no-remote-cache \
    --config "test.v2_test_executor=$executor" \
    --config "nextest_test.observation_dir=$root/observation" \
    --config "nextest_test.nonce=relocated-$$" \
    --event-log "$root/events.json-lines" \
    --test-executor-stdout=- --test-executor-stderr=- \
    //:nextest_buck_test_runtime_closure_positive -- \
    --junit-dir "$root/caller/junit" >"$root/output" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] || { cat "$root/output" >&2; exit "$status"; }
grep -F 'Tests finished:' "$root/output" >/dev/null
! grep -F 'Infra Failure' "$root/output" >/dev/null

(CDPATH= cd -- "$(dirname "$executable")" && find . -mindepth 1 -maxdepth 1 -print | sort) >"$after"
cmp "$before" "$after"
[ "$(checksum "$executable")" = "$exe_digest" ]
[ "$(checksum "$database")" = "$database_digest" ]
[ "$(checksum "$resource")" = "$resource_digest" ]
[ ! -e "${executable}.tmp" ]

observation="$root/observation/runtime-closure-observation.txt"
[ -s "$observation" ]
[ "$(sed -n 's/^executable=//p' "$observation")" = "$executable" ]
[ "$(sed -n 's/^database=//p' "$observation")" = "$database" ]
[ "$(sed -n 's/^resource=//p' "$observation")" = "$resource" ]

report_count=$(find "$root/caller/junit" -mindepth 1 -maxdepth 1 -type f -name '*.xml' | wc -l | tr -d ' ')
[ "$report_count" -eq 1 ]
report=$(find "$root/caller/junit" -mindepth 1 -maxdepth 1 -type f -name '*.xml' -print -quit)
python3 - "$report" <<'PY'
import sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
cases = list(root.iter("testcase"))
assert len(cases) == 1, [case.attrib for case in cases]
assert cases[0].attrib.get("name") == "provider_runtime_resource_case"
assert cases[0].find("failure") is None
PY

"$buck" log what-ran --format json --no-remote "$root/events.json-lines" >"$root/what-ran" 2>"$root/what-ran.err"
python3 - "$root/what-ran" "$executable" <<'PY'
import json
from pathlib import Path
import sys
rows = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
matching = [row for row in rows if row.get("reason") == "test.run" and row.get("identity") == "nextest_buck_test_runtime_closure_positive"]
assert len(matching) == 1, [row.get("identity") for row in rows if row.get("reason") == "test.run"]
command = matching[0].get("reproducer", {}).get("details", {}).get("command")
assert isinstance(command, list), matching[0]
command = [str(value) for value in command]
assert command.count("--declared-input") == 1, command
assert any("runtime_resource_positive_executable" in value for value in command), command
assert not any("nextest_runtime_resource_fixture.rs" in value for value in command), command
assert not any(value in " ".join(command).lower() for value in ("staging", "packaging", "runtime-destination", "runtime_destination")), command
PY

printf '%s\n' 'nextest buck test relocated sanitized: passed'
