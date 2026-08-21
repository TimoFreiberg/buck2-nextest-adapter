#!/usr/bin/env python3
"""Validate Buck2 action metadata for the nextest adapter boundary."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"action-metadata=invalid reason={message}")


def candidates(path: str, root: Path, label: str) -> list[Path]:
    value = Path(path)
    if value.is_absolute():
        result = [value]
    else:
        result = [root / value, Path.cwd() / value]
    if label == "adapter":
        result.append(root / "adapter.sh")
    return result


def digest(path: Path) -> str:
    size = path.stat().st_size
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return f"{h.hexdigest()}:{size}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", required=True)
    for name in (
        "adapter", "cargo-nextest", "python", "cargo", "source-denial",
        "validator", "cargo-baseline", "binary-baseline", "tests-baseline",
        "runtime-resource", "manifest", "artifact",
    ):
        parser.add_argument(f"--{name}", required=True, dest=name.replace("-", "_"))
    args = parser.parse_args()
    metadata_path = Path(args.metadata)
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"metadata-read:{exc}")
    if metadata.get("version") != 1 or not isinstance(metadata.get("digests"), list):
        fail("metadata-schema")

    project = Path.cwd().resolve()
    entries: dict[str, str] = {}
    for item in metadata["digests"]:
        if not isinstance(item, dict) or set(item) != {"path", "digest"}:
            fail("metadata-entry")
        path = item["path"]
        if not isinstance(path, str) or not isinstance(item["digest"], str):
            fail("metadata-entry-type")
        normalized = Path(path).as_posix()
        if normalized in entries:
            fail(f"duplicate-path:{normalized}")
        if Path(normalized).is_absolute() or normalized.startswith("../"):
            fail(f"metadata-path:{normalized}")
        entries[normalized] = item["digest"]

    expected = {
        "adapter": args.adapter,
        "cargo-nextest": args.cargo_nextest,
        "python": args.python,
        "cargo": args.cargo,
        "source-denial": args.source_denial,
        "validator": args.validator,
        "cargo-baseline": args.cargo_baseline,
        "binary-baseline": args.binary_baseline,
        "tests-baseline": args.tests_baseline,
        "runtime-resource": args.runtime_resource,
        "manifest": args.manifest,
        "artifact": args.artifact,
    }
    for label, raw in expected.items():
        found = None
        for candidate in candidates(raw, project, label):
            if candidate.is_file() and not candidate.is_symlink():
                found = candidate.resolve()
                break
        if found is None:
            fail(f"missing:{label}")
        try:
            relative = found.relative_to(project).as_posix()
        except ValueError:
            fail(f"outside-project:{label}")
        metadata_digest = entries.get(relative)
        if metadata_digest is None:
            fail(f"undeclared:{label}:{relative}")
        actual = digest(found)
        if metadata_digest != actual:
            fail(f"digest:{label}")
    print("action-metadata=validated")


if __name__ == "__main__":
    main()
