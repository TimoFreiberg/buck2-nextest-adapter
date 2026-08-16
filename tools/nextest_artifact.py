#!/usr/bin/env python3
"""Strict manifest, baseline, and nextest metadata helper for the local spike."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import subprocess
import sys
from typing import Any

PACKAGE = "buck2-nextest-buck-artifact"
BINARY_ID = "buck2_nextest_rust_test"
BINARY_NAME = "buck2_nextest_rust_test"
CASES = ["pass_case", "fail_case"]


def die(message: str) -> "NoReturn":
    print(f"nextest-artifact: error: {message}", file=sys.stderr)
    raise SystemExit(2)


def strict_load(path: Path) -> Any:
    def duplicate(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    try:
        with path.open(encoding="utf-8") as stream:
            return json.load(stream, object_pairs_hook=duplicate)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        die(f"invalid JSON in {path}: {exc}")


def expect(value: Any, kind: type, name: str) -> Any:
    if not isinstance(value, kind) or (kind is int and isinstance(value, bool)):
        die(f"{name} must be {kind.__name__}")
    return value


def rooted(root: Path, value: Any, name: str, must_exist: bool = True) -> Path:
    expect(value, str, name)
    if not value or os.path.isabs(value):
        die(f"{name} must be a non-empty relative path")
    candidate = PurePosixPath(value)
    if candidate == PurePosixPath("."):
        resolved = root.resolve()
    else:
        if any(part in ("", ".", "..") for part in candidate.parts):
            die(f"{name} contains an unsafe path: {value}")
        current = root
        for part in candidate.parts:
            current = current / part
            if current.is_symlink():
                die(f"{name} must not traverse a symlink: {value}")
        resolved = current.resolve()
    root_resolved = root.resolve()
    try:
        resolved.relative_to(root_resolved)
    except ValueError:
        die(f"{name} escapes the staging root: {value}")
    if must_exist and not resolved.exists():
        die(f"{name} does not exist in staging root: {value}")
    if resolved.is_symlink():
        die(f"{name} must not be a symlink: {value}")
    return resolved


def validate_manifest(path: Path, root: Path, require_paths: bool = True) -> dict[str, Any]:
    data = expect(strict_load(path), dict, "manifest")
    required = {"schema_version", "artifact", "paths", "environment", "platform", "build"}
    if set(data) != required:
        die(f"manifest fields must be exactly {sorted(required)}")
    if data["schema_version"] != 1:
        die("unsupported manifest schema version")
    artifact = expect(data["artifact"], dict, "artifact")
    expected_artifact = {
        "package_name": PACKAGE,
        "binary_id": BINARY_ID,
        "binary_name": BINARY_NAME,
        "target_kind": "test",
        "test_cases": CASES,
    }
    if artifact != expected_artifact:
        die("manifest artifact identity does not match the Buck contract")
    paths = expect(data["paths"], dict, "paths")
    if set(paths) != {"executable", "working_directory", "runtime_inputs"}:
        die("manifest paths have unexpected fields")
    executable = rooted(root, paths["executable"], "paths.executable", must_exist=require_paths)
    working = rooted(root, paths["working_directory"], "paths.working_directory", must_exist=require_paths)
    runtime = expect(paths["runtime_inputs"], list, "paths.runtime_inputs")
    for index, item in enumerate(runtime):
        rooted(root, item, f"paths.runtime_inputs[{index}]", must_exist=require_paths)
    environment = expect(data["environment"], dict, "environment")
    if environment != {"BUCK2_NEXTEST_RUNTIME": "declared"}:
        die("manifest environment does not match the declared runtime contract")
    platform_data = expect(data["platform"], dict, "platform")
    if set(platform_data) != {"target_triple", "target_features"}:
        die("manifest platform fields are invalid")
    expect(platform_data["target_triple"], str, "platform.target_triple")
    expect(platform_data["target_features"], str, "platform.target_features")
    build = expect(data["build"], dict, "build")
    if set(build) != {"generated_outputs"}:
        die("manifest build fields are invalid")
    outputs = expect(build["generated_outputs"], list, "build.generated_outputs")
    for index, item in enumerate(outputs):
        rooted(root, item, f"build.generated_outputs[{index}]", must_exist=require_paths)
    return {"manifest": data, "executable": executable, "working_directory": working}


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def emit_manifest(args: argparse.Namespace) -> None:
    artifact = Path(args.artifact)
    if not artifact.is_file():
        die(f"declared Buck artifact does not exist: {artifact}")
    triple = args.target_triple or f"{platform.machine()}-{platform.system().lower()}"
    manifest = {
        "schema_version": 1,
        "artifact": {
            "package_name": PACKAGE,
            "binary_id": BINARY_ID,
            "binary_name": BINARY_NAME,
            "target_kind": "test",
            "test_cases": CASES,
        },
        "paths": {
            "executable": "bin/buck2_nextest_rust_test",
            "working_directory": "work",
            "runtime_inputs": [],
        },
        "environment": {"BUCK2_NEXTEST_RUNTIME": "declared"},
        "platform": {"target_triple": triple, "target_features": "unknown"},
        "build": {"generated_outputs": []},
    }
    write_json(Path(args.output), manifest)


def replace_paths(value: Any, replacements: list[tuple[str, str]]) -> Any:
    if isinstance(value, str):
        for old, new in replacements:
            value = value.replace(old, new)
        return value
    if isinstance(value, list):
        return [replace_paths(item, replacements) for item in value]
    if isinstance(value, dict):
        return {key: replace_paths(item, replacements) for key, item in value.items()}
    return value


def synthetic_metadata(args: argparse.Namespace) -> None:
    manifest = validate_manifest(Path(args.manifest), Path(args.manifest_root), require_paths=False)["manifest"]
    platform_data = manifest["platform"]
    baseline_cargo = strict_load(Path(args.cargo_baseline))
    baseline_binary = strict_load(Path(args.binary_baseline))
    baseline_tests = strict_load(Path(args.tests_baseline))
    if len(baseline_binary.get("rust-binaries", {})) != 3:
        die("baseline binary shape changed: expected one lib and two test binaries")
    if baseline_tests.get("test-count") != 2:
        die("baseline test shape changed: expected two test cases")
    target = Path(args.target_dir).resolve()
    workspace = Path(args.workspace).resolve()
    workspace_uri = workspace.as_uri()
    package_id = f"{workspace_uri}#{PACKAGE}@0.1.0"
    cargo = copy.deepcopy(baseline_cargo)
    package = cargo["packages"][0]
    package["id"] = package_id
    package["source"] = None
    package["name"] = PACKAGE
    package["manifest_path"] = str(workspace / "Cargo.toml")
    package["root"] = str(workspace)
    package["targets"] = [{
        "crate_types": ["bin"],
        "doc": False,
        "doctest": False,
        "edition": "2021",
        "kind": ["test"],
        "name": BINARY_NAME,
        "required-features": [],
        "src_path": str(workspace / "src" / "buck2_artifact.rs"),
        "test": True,
    }]
    cargo["workspace_root"] = str(workspace)
    cargo["target_directory"] = str(target)
    cargo["resolve"]["root"] = package_id
    cargo["resolve"]["nodes"] = [{"id": package_id, "dependencies": [], "deps": [], "features": []}]
    cargo["workspace_members"] = [package_id]
    cargo["workspace_default_members"] = [package_id]
    replacements = [
        (str(Path(baseline_binary["rust-build-meta"]["target-directory"])), str(target)),
        (str(Path(baseline_binary["rust-build-meta"]["build-directory"])), str(target)),
    ]
    build_meta = replace_paths(baseline_binary["rust-build-meta"], replacements)
    build_meta["target-directory"] = str(target)
    build_meta["build-directory"] = str(target)
    build_meta["base-output-directories"] = ["debug"]
    build_meta["platforms"]["host"]["platform"] = {
        "target-features": platform_data["target_features"],
        "triple": platform_data["target_triple"],
    }
    build_meta["target-platforms"] = [{
        "target-features": platform_data["target_features"],
        "triple": platform_data["target_triple"],
    }]
    binary_path = str(target / "debug" / "deps" / BINARY_NAME)
    binary = {
        "binary-id": BINARY_ID,
        "binary-name": BINARY_NAME,
        "binary-path": binary_path,
        "build-platform": "target",
        "kind": "test",
        "package-id": package_id,
    }
    binaries = {"rust-build-meta": build_meta, "rust-binaries": {BINARY_ID: binary}}
    suite = {
        "binary-id": BINARY_ID,
        "binary-name": BINARY_NAME,
        "binary-path": binary_path,
        "build-platform": "target",
        "cwd": str(workspace),
        "kind": "test",
        "package-id": package_id,
        "package-name": PACKAGE,
        "status": "listed",
        "testcases": {
            case: {"filter-match": {"status": "matches"}, "ignored": False, "kind": "test"}
            for case in CASES
        },
    }
    tests = {"rust-build-meta": build_meta, "rust-suites": {BINARY_ID: suite}, "test-count": 2}
    out = Path(args.output_dir)
    write_json(out / "cargo-metadata.json", cargo)
    write_json(out / "binaries-metadata.json", binaries)
    write_json(out / "tests-metadata.json", tests)


def normalize_baseline(args: argparse.Namespace) -> None:
    raw = Path(args.raw_dir).resolve()
    out = Path(args.output_dir)
    cargo = strict_load(raw / "cargo-metadata.json")
    binaries = strict_load(raw / "binaries.json")
    tests = strict_load(raw / "tests.json")
    raw_variants = {str(raw), str(raw).replace("/private", "", 1), str(raw).replace("//", "/")}
    replacements = []
    for raw_root in raw_variants:
        for suffix in ("", "/"):
            replacements.extend([
                (raw_root + suffix + "fixture", "<WORKSPACE>/fixture"),
                (raw_root + suffix + "target", "<TARGET_DIR>"),
            ])
    normalized = []
    for value in (cargo, binaries, tests):
        value = replace_paths(value, replacements)
        text = json.dumps(value, sort_keys=True)
        text = re.sub(r"/var/folders/[^\"]+/T//buck2-nextest-baseline\.[^/\"]+", "<BASELINE_ROOT>", text)
        text = re.sub(r"/Users/[^\"]+/.rustup/toolchains/[^\"]+/lib/rustlib/[^\"]+/lib", "<RUST_LIBDIR>", text)
        normalized.append(json.loads(text))
    write_json(out / "cargo-metadata.json", normalized[0])
    write_json(out / "binaries.json", normalized[1])
    write_json(out / "tests.json", normalized[2])
    summary = {
        "schema": 1,
        "observed_package": "buck2-nextest-fixture",
        "observed_test_binaries": ["fail_case", "pass_case"],
        "observed_test_cases": CASES,
        "normalized_paths": {"workspace": "<WORKSPACE>", "target_directory": "<TARGET_DIR>", "rust_libdir": "<RUST_LIBDIR>"},
        "consumed_fields": ["package-id", "package-name", "binary-id", "binary-name", "kind", "binary-path", "cwd", "testcases", "platforms", "linked-paths", "build-script-out-dirs", "environment"],
    }
    write_json(out / "summary.json", summary)


def digest(args: argparse.Namespace) -> None:
    path = Path(args.path)
    h = hashlib.sha256(path.read_bytes()).hexdigest()
    print(h)


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("emit-manifest")
    p.add_argument("--output", required=True)
    p.add_argument("--artifact", required=True)
    p.add_argument("--target-triple")
    p.set_defaults(func=emit_manifest)
    p = sub.add_parser("validate-manifest")
    p.add_argument("--manifest", required=True)
    p.add_argument("--root", required=True)
    p.add_argument("--allow-missing", action="store_true")
    p.set_defaults(func=lambda args: (validate_manifest(Path(args.manifest), Path(args.root), not args.allow_missing), print("manifest valid")))
    p = sub.add_parser("synthesize")
    p.add_argument("--cargo-baseline", required=True)
    p.add_argument("--binary-baseline", required=True)
    p.add_argument("--tests-baseline", required=True)
    p.add_argument("--target-dir", required=True)
    p.add_argument("--workspace", required=True)
    p.add_argument("--output-dir", required=True)
    p.add_argument("--manifest", required=True)
    p.add_argument("--manifest-root", required=True)
    p.set_defaults(func=synthetic_metadata)
    p = sub.add_parser("normalize-baseline")
    p.add_argument("--raw-dir", required=True)
    p.add_argument("--output-dir", required=True)
    p.set_defaults(func=normalize_baseline)
    p = sub.add_parser("digest")
    p.add_argument("path")
    p.set_defaults(func=digest)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
