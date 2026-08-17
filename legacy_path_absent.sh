#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
! grep -F 'cargo-fixture' "$root/adapter.sh"
! grep -F 'nextest_spike' "$root/BUCK"
! grep -F 'cargo-fixture' "$root/BUCK"
python3 - "$root/BUCK" <<'PY'
import sys
text = open(sys.argv[1]).read()
start = text.index('name = "nextest_buck_artifact_runner"')
end = text.index('\n)', start) + 2
block = text[start:end]
assert 'fixture/' not in block
assert 'buck_artifact_export_fault.sh' not in block
PY
[ -f "$root/fixture/Cargo.toml" ]
[ -f "$root/tools/capture_cargo_nextest_baseline.sh" ]
printf '%s\n' 'legacy path absence: passed'
