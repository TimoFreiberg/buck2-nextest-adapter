#!/usr/bin/env python3
"""Pure regression tests for the generic Buck artifact contract."""
from __future__ import annotations

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import nextest_artifact


GOOD_RECORD = {
    "package_identity": "package;α",
    "owner_label": "//:owner_name",
    "binary_identity": "binary=one",
    "display_name": "same display",
    "target_kind": "test",
    "executable": {"source": "source/bin", "kind": "regular_file"},
    "cwd": "work",
    "platform": "aarch64-apple-darwin",
}


def test_semantic_id_round_trip_and_collision_resistance() -> None:
    vectors = [
        ("package;α", "//:owner_name", "binary=one"),
        ("a", "bc", "d"),
        ("a", "b", "cd"),
        ("a/b", "a;b", "a=b%~"),
        ("unicode-☃", "//:λ", "二进制"),
    ]
    encoded = [nextest_artifact.semantic_id(*vector) for vector in vectors]
    assert len(set(encoded)) == len(vectors)
    for vector, value in zip(vectors, encoded):
        assert nextest_artifact.decode_semantic_id(value) == vector
    assert encoded[0].startswith("b2n1:p=")
    assert ";o=" in encoded[0] and ";b=" in encoded[0]
    malformed = [
        "b1:p=a;o=b;b=c",
        "b2n1:p=a;o=b;b=c;tail=x",
        "b2n1:p=%61;o=b;b=c",
        "b2n1:p=a;o=b;b=%c3%28",
        "b2n1:p=a;o=b;b=%2f",
        "b2n1:p=;o=b;b=c",
    ]
    for value in malformed:
        process = subprocess.run(
            [sys.executable, str(ROOT / "tools/nextest_artifact.py"), "decode-semantic-id", value],
            text=True,
            capture_output=True,
        )
        assert process.returncode == 2, (value, process.stdout, process.stderr)


def test_generic_manifest_positive_and_negative_cases() -> None:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "manifest.json"
        manifest = {"schema_version": 2, "records": [copy.deepcopy(GOOD_RECORD)]}
        path.write_text(json.dumps(manifest), encoding="utf-8")
        assert nextest_artifact.validate_generic_manifest(path)["records"][0]["id"].startswith("b2n1:")
        cases = {
            "duplicate-triple": lambda item: item,
            "duplicate-executable": lambda item: item,
            "multiple-executables": lambda item: item,
            "missing-platform": lambda item: item,
            "unknown-runtime": lambda item: item,
            "unknown-generated-output": lambda item: item,
            "overlap-executable-parent": lambda item: item,
            "unsafe-cwd-quote": lambda item: item,
            "unsafe-cwd-control": lambda item: item,
            "cross-package-cwd": lambda item: item,
        }
        for name in cases:
            candidate = copy.deepcopy(manifest)
            if name == "duplicate-triple":
                candidate["records"].append(copy.deepcopy(GOOD_RECORD))
            elif name == "duplicate-executable":
                other = copy.deepcopy(GOOD_RECORD)
                other["binary_identity"] = "other"
                candidate["records"].append(other)
            elif name == "multiple-executables":
                candidate["records"][0]["executable"] = [GOOD_RECORD["executable"], GOOD_RECORD["executable"]]
            elif name == "missing-platform":
                del candidate["records"][0]["platform"]
            elif name == "unknown-runtime":
                candidate["records"][0]["runtime"] = []
            elif name == "unknown-generated-output":
                candidate["records"][0]["generated_outputs"] = []
            elif name == "overlap-executable-parent":
                candidate["records"][0]["executable"]["source"] = "source/bin/file"
            elif name == "overlap-cwd-parent":
                candidate["records"][0]["cwd"] = "work/subdir"
                candidate["records"][0]["executable"]["source"] = "work/subdir/bin/test"
            elif name == "unsafe-cwd-quote":
                candidate["records"][0]["cwd"] = 'work"quoted'
            elif name == "unsafe-cwd-control":
                candidate["records"][0]["cwd"] = "work\nline"
            elif name == "cross-package-cwd":
                other = copy.deepcopy(GOOD_RECORD)
                other["package_identity"] = "other-package"
                other["binary_identity"] = "other-binary"
                other["cwd"] = "work/nested"
                other["executable"]["source"] = "other/bin"
                candidate["records"].append(other)
            path.write_text(json.dumps(candidate), encoding="utf-8")
            process = subprocess.run(
                [sys.executable, str(ROOT / "tools/nextest_buck_test_contract.py"), "--manifest", str(path), "--record-count", str(len(candidate["records"]))],
                text=True,
                capture_output=True,
            )
            assert process.returncode == 2, (name, process.stdout, process.stderr)


if __name__ == "__main__":
    test_semantic_id_round_trip_and_collision_resistance()
    test_generic_manifest_positive_and_negative_cases()
    print("semantic contract tests passed")
