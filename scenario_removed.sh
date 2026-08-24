#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-$(pwd -P)}
project=${BUCK_PROJECT_ROOT:-$root}
[ -d "$project" ]
python3 - "$project" <<'PY'
from pathlib import Path
import subprocess
import sys

project = Path(sys.argv[1])
result = subprocess.run(
    [
        "git",
        "-C",
        str(project),
        "ls-files",
        "-z",
        "--",
        "*.sh",
        "*.bzl",
        "BUCK",
        "README.md",
        "docs/*.md",
        "docs/*.sh",
    ],
    check=True,
    stdout=subprocess.PIPE,
)
files = [raw for raw in result.stdout.split(b"\0") if raw]
if not files:
    raise SystemExit("tracked migration scan is empty")
legacy_switch = b"--" + b"scenario"
for raw in files:
    path = project / raw.decode(errors="surrogateescape")
    # Missing tracked files are pending deletions and contain no working-tree text.
    if path.is_file() and legacy_switch in path.read_bytes():
        raise SystemExit(
            f"removed legacy scenario switch remains in {path.relative_to(project)}"
        )
PY
printf '%s\n' 'scenario removed: passed'
