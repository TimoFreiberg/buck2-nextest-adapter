#!/bin/sh
set -eu

root=$(mktemp -d "${TMPDIR:-/tmp}/buck2-nextest-baseline.XXXXXX")
cleanup() { rm -rf "$root"; }
trap cleanup EXIT HUP INT TERM

output=${1:-baseline/normalized}
mkdir -p "$root/fixture" "$output"
cp -R fixture/. "$root/fixture/"
export CARGO_NET_OFFLINE=${CARGO_NET_OFFLINE:-true}
export CARGO_TARGET_DIR="$root/target"

cargo --version >"$root/cargo.version"
rustc --version >"$root/rustc.version"
cargo nextest --version >"$root/nextest.version"
buck2 --version >"$root/buck2.version"
rustc -vV >"$root/rustc-vV"

cargo metadata --manifest-path "$root/fixture/Cargo.toml" --locked --format-version 1 >"$root/cargo-metadata.json"
cargo nextest list --manifest-path "$root/fixture/Cargo.toml" --locked --list-type binaries-only --message-format json >"$root/binaries.json"
cargo nextest list --manifest-path "$root/fixture/Cargo.toml" --locked --message-format json >"$root/tests.json"

python3 tools/nextest_artifact.py normalize-baseline --raw-dir "$root" --output-dir "$output"
python3 - "$root" "$output" <<'PY'
import hashlib
import pathlib
import shutil
import sys

raw = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
for name in ("cargo.version", "rustc.version", "nextest.version", "buck2.version", "rustc-vV"):
    (out / name).write_text((raw / name).read_text(), encoding="utf-8")

before = hashlib.sha256()
for path in sorted(pathlib.Path("fixture").rglob("*")):
    if path.is_file():
        before.update(str(path).encode())
        before.update(path.read_bytes())
(out / "fixture-digest.sha256").write_text(before.hexdigest() + "\n", encoding="utf-8")
PY
printf 'baseline written to %s\n' "$output"
