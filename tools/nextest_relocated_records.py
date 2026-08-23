#!/usr/bin/python3
"""Write and merge relocation harness process records."""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
import tempfile
import time
from pathlib import Path

DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
IDENTITY_KEYS = {
    "python_buck_output_path",
    "python_buck_output_digest",
    "python_launcher_path",
    "python_launcher_digest",
    "python_interpreter_path",
    "python_interpreter_digest",
    "nextest_buck_output_path",
    "nextest_buck_output_digest",
    "nextest_fixture_path",
    "nextest_fixture_digest",
}
PROCESS_IDENTITY_KEYS = IDENTITY_KEYS - {
    "python_buck_output_path",
    "python_buck_output_digest",
    "nextest_buck_output_path",
    "nextest_buck_output_digest",
}
OBSERVABILITY_KEYS = {"cwd", "path", "checksum_command"}


def digest(path: Path) -> str:
    if not path.is_absolute():
        path = Path(os.environ.get("BUCK_PROJECT_ROOT", ".")) / path
    if not path.is_file() or path.is_symlink():
        raise SystemExit(f"record helper: not a regular file: {path}")
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def sequence_record(directory: Path, prefix: str, fields: list[tuple[str, str]]) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{prefix}", suffix=".tmp", dir=directory)
    path = Path(name)
    final = directory / f"{prefix}{path.name.removeprefix(f'.{prefix}').removesuffix('.tmp')}.record"
    fields = [(key, final.name if key == "sequence" else value) for key, value in fields]
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write("".join(f"{key}={value}\n" for key, value in fields))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(path, final)
    except BaseException:
        path.unlink(missing_ok=True)
        raise


def checksum_command() -> str:
    for name in ("sha256sum", "shasum"):
        if any(Path(item or ".").joinpath(name).is_file() for item in os.environ.get("PATH", "").split(os.pathsep)):
            return name
    return ""


def common(process: str, phase: str, cwd: str) -> list[tuple[str, str]]:
    sequence = os.environ.get("ADAPTER_RELOCATED_RECORD_PREFIX", "record")
    return [
        ("process", process),
        ("phase", phase),
        ("sequence", sequence),
        ("cwd", cwd),
        ("path", os.environ.get("PATH", "")),
        ("checksum_command", checksum_command()),
    ]


def write_launcher(args: argparse.Namespace) -> None:
    directory = Path(os.environ["ADAPTER_RELOCATED_RECORD_DIR"])
    helper = Path(args.path)
    sequence_record(
        directory,
        "launcher.",
        common("launcher", args.phase, os.getcwd())
        + [
            ("python_launcher_path", str(helper)),
            ("python_launcher_digest", digest(helper)),
            ("python_interpreter_path", "/usr/bin/python3"),
            ("python_interpreter_digest", digest(Path("/usr/bin/python3"))),
        ],
    )


def write_fixture(args: argparse.Namespace) -> None:
    directory = Path(os.environ["ADAPTER_RELOCATED_RECORD_DIR"])
    fixture = Path(args.path)
    sequence_record(
        directory,
        "fixture.",
        common("fixture", "nextest", os.getcwd())
        + [
            ("nextest_fixture_path", str(fixture)),
            ("nextest_fixture_digest", digest(fixture)),
        ],
    )


def parse_record(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or "=" not in line:
            raise SystemExit(f"record helper: malformed record={path}")
        key, value = line.split("=", 1)
        if key in result:
            raise SystemExit(f"record helper: duplicate key={key}")
        result[key] = value
    for key in ("process", "phase", "sequence", "cwd", "path", "checksum_command"):
        if key not in result:
            raise SystemExit(f"record helper: missing key={key}")
    return result


def write_atomic(destination: Path, content: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def merge(args: argparse.Namespace) -> None:
    source = Path(args.source)
    lock = source / ".merge.lock"
    acquired = False
    for _ in range(200):
        try:
            fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
            acquired = True
            break
        except FileExistsError:
            time.sleep(0.01)
    if not acquired:
        raise SystemExit("record helper: merge lock timeout")
    try:
        _merge_locked(args, source)
    finally:
        lock.unlink(missing_ok=True)


def _merge_locked(args: argparse.Namespace, source: Path) -> None:
    records = sorted(source.glob("*.record"))
    if not records:
        raise SystemExit("record helper: no process records")
    observations: list[dict[str, str]] = []
    identity: dict[str, str] = {}
    destination = Path(args.identity)
    if destination.exists() and destination.stat().st_size:
        for line in destination.read_text(encoding="utf-8").splitlines():
            if not line or "=" not in line:
                raise SystemExit(f"record helper: malformed identity={destination}")
            key, value = line.split("=", 1)
            if key in identity:
                raise SystemExit(f"record helper: duplicate identity key={key}")
            identity[key] = value
    if set(identity) - IDENTITY_KEYS:
        extra = sorted(set(identity) - IDENTITY_KEYS)
        raise SystemExit(f"record helper: identity schema mismatch extra={','.join(extra)}")
    seen_sequences: dict[tuple[str, str, str], str] = {}
    for path in records:
        row = parse_record(path)
        record_text = path.read_text(encoding="utf-8")
        identity_fields = {key: row[key] for key in PROCESS_IDENTITY_KEYS if key in row}
        for key, value in identity_fields.items():
            if key in identity and identity[key] != value:
                raise SystemExit(f"record helper: conflicting key={key}")
            identity[key] = value
        key = (row["process"], row["phase"], row["sequence"])
        if key in seen_sequences:
            if seen_sequences[key] != record_text:
                raise SystemExit("record helper: duplicate process phase sequence")
            continue
        seen_sequences[key] = record_text
        observations.append(row)
    required = IDENTITY_KEYS
    if set(identity) != required:
        missing = sorted(required - set(identity))
        extra = sorted(set(identity) - required)
        raise SystemExit(f"record helper: identity schema mismatch missing={','.join(missing)} extra={','.join(extra)}")
    for key in PROCESS_IDENTITY_KEYS:
        if not key.endswith("_digest"):
            continue
        value = identity[key]
        if not DIGEST_RE.fullmatch(value):
            raise SystemExit(f"record helper: invalid digest key={key}")
        path_key = key.removesuffix("_digest") + "_path"
        if path_key not in identity:
            raise SystemExit(f"record helper: missing path key={path_key}")
        path = Path(identity[path_key])
        if digest(path) != value:
            raise SystemExit(f"record helper: digest mismatch key={key}")
    for key in ("python_buck_output_digest", "nextest_buck_output_digest"):
        if not DIGEST_RE.fullmatch(identity[key]):
            raise SystemExit(f"record helper: invalid digest key={key}")
        path_key = key.removesuffix("_digest") + "_path"
        if digest(Path(identity[path_key])) != identity[key]:
            raise SystemExit(f"record helper: digest mismatch key={key}")
    write_atomic(Path(args.identity), "".join(f"{key}={identity[key]}\n" for key in sorted(identity)))
    expected = {"process", "phase", "sequence", "cwd", "path", "checksum_command"}
    observation_text = []
    for row in observations:
        if set(row) - expected - IDENTITY_KEYS:
            raise SystemExit("record helper: unknown observation key")
        observation_text.append("".join(f"{key}={row[key]}\n" for key in sorted(expected) if key in row))
    write_atomic(Path(args.observability), "".join(observation_text))
    

def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    launcher = sub.add_parser("write-launcher")
    launcher.add_argument("path")
    launcher.add_argument("phase")
    fixture = sub.add_parser("write-fixture")
    fixture.add_argument("path")
    merger = sub.add_parser("merge")
    merger.add_argument("source")
    merger.add_argument("identity")
    merger.add_argument("observability")
    args = parser.parse_args()
    {"write-launcher": write_launcher, "write-fixture": write_fixture, "merge": merge}[args.command](args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
