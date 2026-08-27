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
    "executable": {"source": "source/bin", "destination": "bin/test", "kind": "regular_file"},
    "runtime": [{"source": "source/runtime", "destination": "runtime/file", "kind": "regular_file"}],
    "generated_outputs": [],
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
            "unsafe-runtime": lambda item: item,
            "missing-platform": lambda item: item,
            "generated-output": lambda item: item,
            "overlap-executable-parent": lambda item: item,
            "overlap-cwd-parent": lambda item: item,
            "unsafe-cwd-quote": lambda item: item,
            "unsafe-cwd-control": lambda item: item,
            "cross-package-cwd": lambda item: item,
            "cross-package-destination": lambda item: item,
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
            elif name == "unsafe-runtime":
                candidate["records"][0]["runtime"][0]["destination"] = "../escape"
            elif name == "missing-platform":
                del candidate["records"][0]["platform"]
            elif name == "generated-output":
                candidate["records"][0]["generated_outputs"] = [{"destination": "generated/file"}]
            elif name == "overlap-executable-parent":
                candidate["records"][0]["runtime"][0]["destination"] = "bin/test/file"
            elif name == "overlap-cwd-parent":
                candidate["records"][0]["cwd"] = "work/subdir"
                candidate["records"][0]["runtime"][0]["destination"] = "work"
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
                other["executable"]["destination"] = "work/nested/bin/test"
                other["runtime"][0]["source"] = "other/runtime"
                other["runtime"][0]["destination"] = "work/nested/runtime/file"
                candidate["records"].append(other)
            elif name == "cross-package-destination":
                other = copy.deepcopy(GOOD_RECORD)
                other["package_identity"] = "other-package"
                other["binary_identity"] = "other-binary"
                other["cwd"] = "other-work"
                other["executable"]["source"] = "other/bin"
                other["executable"]["destination"] = "work/other-package/bin/test"
                other["runtime"][0]["source"] = "other/runtime"
                other["runtime"][0]["destination"] = "other-work/runtime/file"
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
