#!/bin/sh
set -eu
fixture=${1:?missing fixture executable}
root=$(mktemp -d "${TMPDIR:-/tmp}/schema-v2-fixture.XXXXXX")
trap 'rm -rf "$root"' EXIT
mkdir "$root/observation"
nonce="fixture-contract-$$"
NEXTEST_TEST_OBSERVATION_DIR="$root/observation" NEXTEST_TEST_NONCE="$nonce" "$fixture" --exact cancellation_case --nocapture >"$root/output" 2>&1 &
pid=$!
for _ in $(seq 1 100); do
    [ -f "$root/observation/state.json" ] && break
    kill -0 "$pid" 2>/dev/null || { cat "$root/output" >&2; exit 1; }
    sleep .1
done
[ -f "$root/observation/state.json" ]
python3 - "$root/observation/state.json" "$nonce" "$pid" <<'PY'
import json, sys
from pathlib import Path
value = json.loads(Path(sys.argv[1]).read_text())
assert set(value) == {"schema", "nonce", "test_pid", "test_start_identity", "ready"}, value
assert value["schema"] == 1 and value["nonce"] == sys.argv[2] and value["ready"] is True, value
assert value["test_pid"] == int(sys.argv[3]), value
assert isinstance(value["test_start_identity"], str) and value["test_start_identity"], value
PY
kill -TERM "$pid" 2>/dev/null || true
set +e
wait "$pid"
status=$?
set -e
[ "$status" -ne 0 ] || { cat "$root/output" >&2; exit 1; }
printf '%s\n' 'schema-v2 fixture contract: passed'
