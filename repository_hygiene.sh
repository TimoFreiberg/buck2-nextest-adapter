#!/bin/sh
set -eu

project=${BUCK_PROJECT_ROOT:-$(CDPATH= cd -- "$(dirname "$0")" && pwd)}
cd "$project"

tracked=$(mktemp "${TMPDIR:-/tmp}/repository-hygiene.XXXXXX")
trap 'rm -f "$tracked"' EXIT HUP INT TERM
git ls-files -z >"$tracked"

python3 - "$project" "$tracked" <<'PY'
import os
from pathlib import Path
import sys

project = Path(sys.argv[1])
paths = [p for p in Path(sys.argv[2]).read_bytes().split(b"\0") if p]
personal = {
    b"delete-old-" + b"polytoken-session-logs.sh",
    b"delete-" + b"pantoken-cargo-target.sh",
}
failed = False
for raw in paths:
    rel = os.fsdecode(raw)
    path = project / rel
    # Missing tracked paths are pending deletions; final VCS review verifies them.
    if not path.exists() or rel.startswith("buck-out/"):
        continue
    parts = Path(rel).parts
    if "__pycache__" in parts or Path(rel).suffix in {".pyc", ".pyo", ".pyd"}:
        print(f"present tracked Python bytecode: {rel}", file=sys.stderr)
        failed = True
    if raw in personal:
        continue
    if path.is_file():
        try:
            data = path.read_bytes()
        except OSError as error:
            print(f"cannot inspect tracked file {rel}: {error}", file=sys.stderr)
            failed = True
            continue
        for name in personal:
            if name in data:
                print(f"tracked project reference to personal cleanup script: {rel}", file=sys.stderr)
                failed = True
                break
if failed:
    raise SystemExit(1)
PY

for sentinel in tools/__pycache__/repository_hygiene.cpython-311.pyc docs/repository_hygiene.pyc; do
    if ! git check-ignore -q --no-index "$sentinel"; then
        printf 'required Python bytecode ignore missing for %s\n' "$sentinel" >&2
        exit 1
    fi
done

# The third-party dependency graph (Cargo.lock, generated BUCK, pinned reindeer
# metadata, and the auditable dependency note) is verified structurally by the
# stdlib-only checker; it must stay green whenever the graph or reindeer
# version changes. Regenerate the note with:
#   python3 third-party/check_dependencies.py update-note third-party
python3 "$project/third-party/check_dependencies.py" check "$project/third-party"

printf '%s\n' 'repository hygiene: passed'
