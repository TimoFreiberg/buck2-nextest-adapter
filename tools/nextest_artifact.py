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
import stat
import subprocess
import sys
import time
from typing import Any

PACKAGE = "buck2-nextest-buck-artifact"
BINARY_ID = "buck2_nextest_rust_test"
BINARY_NAME = "buck2_nextest_rust_test"
CASES = [
    {"name": "pass_case", "ignored": False},
    {"name": "fail_case", "ignored": False},
    {"name": "ignored_case", "ignored": True},
    {"name": "timeout_case", "ignored": False},
]
BASELINE_OBSERVED_CASES = ["pass_case", "fail_case"]


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


def validate_test_cases(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        die("artifact.test_cases must be a list")
    records: list[dict[str, Any]] = []
    names: set[str] = set()
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            die(f"artifact.test_cases[{index}] must be an object")
        if set(item) != {"name", "ignored"}:
            die(f"artifact.test_cases[{index}] fields must be exactly ['ignored', 'name']")
        name = item["name"]
        if not isinstance(name, str):
            die(f"artifact.test_cases[{index}].name must be str")
        if not name:
            die(f"artifact.test_cases[{index}].name must not be empty")
        if name in names:
            die(f"artifact.test_cases contains duplicate name: {name}")
        names.add(name)
        ignored = item["ignored"]
        if type(ignored) is not bool:
            die(f"artifact.test_cases[{index}].ignored must be bool")
        records.append({"name": name, "ignored": ignored})
    if records != CASES:
        die("artifact.test_cases must exactly match the required ordered records")
    return records


ENVIRONMENT_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
ADAPTER_OWNED_PATHS = (
    "manifest.json",
    "nextest_artifact.py",
    "cargo",
    "rustc",
    "baseline-cargo.json",
    "baseline-binaries.json",
    "baseline-tests.json",
    "dispatch.log",
    "nested-cargo.log",
    "compiler.log",
    "workspace",
    "target",
    "meta",
)

RESERVED_ENVIRONMENT_NAMES = {
    "PATH",
    "CARGO_NET_OFFLINE",
    "CARGO_TARGET_DIR",
    "CARGO_MANIFEST_DIR",
    "CARGO_HOME",
    "BUCK2_NEXTEST_REAL_CARGO",
    "BUCK2_NEXTEST_DISPATCH_LOG",
    "BUCK2_NEXTEST_NESTED_CARGO_LOG",
    "BUCK2_NEXTEST_COMPILER_LOG",
    "BUCK2_NEXTEST_DISPATCH_ALLOWED",
    "BUCK2_NEXTEST_REQUIRE_PROCESS_GROUP",
}


def rooted(root: Path, value: Any, name: str, must_exist: bool = True) -> Path:
    expect(value, str, name)
    if not value or "\x00" in value or os.path.isabs(value):
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


def path_parts(value: str) -> tuple[str, ...]:
    return PurePosixPath(value).parts


def is_prefix(ancestor: tuple[str, ...], child: tuple[str, ...]) -> bool:
    return len(ancestor) <= len(child) and child[:len(ancestor)] == ancestor


def reserved_environment_name(name: str) -> bool:
    return name in RESERVED_ENVIRONMENT_NAMES or name.startswith("BUCK2_NEXTEST_")


def validate_manifest(path: Path, root: Path, require_paths: bool = True) -> dict[str, Any]:
    data = expect(strict_load(path), dict, "manifest")
    required = {"schema_version", "artifact", "paths", "environment", "platform", "build"}
    if set(data) != required:
        die(f"manifest fields must be exactly {sorted(required)}")
    if data["schema_version"] != 1:
        die("unsupported manifest schema version")
    artifact = expect(data["artifact"], dict, "artifact")
    records = validate_test_cases(artifact.get("test_cases"))
    expected_artifact = {
        "package_name": PACKAGE,
        "binary_id": BINARY_ID,
        "binary_name": BINARY_NAME,
        "target_kind": "test",
        "test_cases": records,
    }
    if artifact != expected_artifact:
        die("manifest artifact identity does not match the Buck contract")
    paths = expect(data["paths"], dict, "paths")
    if set(paths) != {"executable", "working_directory", "runtime_inputs"}:
        die("manifest paths have unexpected fields")
    executable_name = expect(paths["executable"], str, "paths.executable")
    working_name = expect(paths["working_directory"], str, "paths.working_directory")
    executable = rooted(root, executable_name, "paths.executable", must_exist=require_paths)
    working = rooted(root, working_name, "paths.working_directory", must_exist=require_paths)
    runtime = expect(paths["runtime_inputs"], list, "paths.runtime_inputs")
    runtime_names: list[str] = []
    runtime_paths: list[Path] = []
    for index, item in enumerate(runtime):
        item = expect(item, str, f"paths.runtime_inputs[{index}]")
        if item in runtime_names:
            die(f"paths.runtime_inputs contains a duplicate path: {item}")
        runtime_names.append(item)
        runtime_paths.append(rooted(root, item, f"paths.runtime_inputs[{index}]", must_exist=require_paths))
    executable_parts = path_parts(executable_name)
    working_parts = path_parts(working_name)
    for name in runtime_names:
        parts = path_parts(name)
        if is_prefix(parts, executable_parts) or is_prefix(parts, working_parts):
            die(f"runtime input conflicts with executable or working directory: {name}")
        for owned in ADAPTER_OWNED_PATHS:
            owned_parts = path_parts(owned)
            if is_prefix(parts, owned_parts) or is_prefix(owned_parts, parts):
                die(f"runtime input conflicts with adapter-owned path: {name}")
    if is_prefix(executable_parts, working_parts) or is_prefix(working_parts, executable_parts):
        die("paths.executable and paths.working_directory overlap")
    if require_paths:
        if not executable.is_file() or executable.is_symlink() or not os.access(executable, os.X_OK):
            die("paths.executable must be an executable regular file")
        if not working.is_dir() or working.is_symlink():
            die("paths.working_directory must be a directory")
        for index, item in enumerate(runtime_paths):
            if not item.is_file() or item.is_symlink():
                die(f"paths.runtime_inputs[{index}] must be a regular file")
    environment = expect(data["environment"], dict, "environment")
    for name, value in environment.items():
        expect(name, str, "environment key")
        if not ENVIRONMENT_NAME.fullmatch(name):
            die(f"environment name is invalid: {name}")
        expect(value, str, f"environment.{name}")
        if "\x00" in name or "\x00" in value:
            die(f"environment.{name} contains a NUL byte")
        if reserved_environment_name(name):
            die(f"environment name is adapter-owned: {name}")
    platform_data = expect(data["platform"], dict, "platform")
    if set(platform_data) != {"target_triple", "target_features"}:
        die("manifest platform fields are invalid")
    expect(platform_data["target_triple"], str, "platform.target_triple")
    expect(platform_data["target_features"], str, "platform.target_features")
    build = expect(data["build"], dict, "build")
    if set(build) != {"generated_outputs"}:
        die("manifest build fields are invalid")
    outputs = expect(build["generated_outputs"], list, "build.generated_outputs")
    if outputs:
        die("build.generated_outputs must be empty in manifest schema version 1")
    return {
        "manifest": data,
        "test_cases": records,
        "executable": executable,
        "working_directory": working,
        "runtime_paths": runtime_paths,
    }


def write_json(path: Path, value: Any, *, sort_keys: bool = True) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=sort_keys) + "\n", encoding="utf-8")


def emit_manifest(args: argparse.Namespace) -> None:
    artifact = Path(args.artifact)
    if not artifact.is_file():
        die(f"declared Buck artifact does not exist: {artifact}")
    triple = args.target_triple or f"{platform.machine()}-{platform.system().lower()}"
    runtime_input = args.runtime_input
    if not runtime_input:
        die("--runtime-input is required")
    runtime_path = Path(args.runtime_source)
    if not runtime_path.is_file() or runtime_path.is_symlink():
        die(f"declared runtime input does not exist: {runtime_path}")
    environment = {"BUCK2_ARTIFACT_RUNTIME": args.runtime_environment}
    manifest = {
        "schema_version": 1,
        "artifact": {
            "package_name": PACKAGE,
            "binary_id": BINARY_ID,
            "binary_name": BINARY_NAME,
            "target_kind": "test",
            "test_cases": copy.deepcopy(CASES),
        },
        "paths": {
            "executable": "bin/buck2_nextest_rust_test",
            "working_directory": "work",
            "runtime_inputs": [runtime_input],
        },
        "environment": environment,
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
    result = validate_manifest(Path(args.manifest), Path(args.manifest_root), require_paths=False)
    manifest = result["manifest"]
    records = result["test_cases"]
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
        "cwd": str((Path(args.manifest_root).resolve() / manifest["paths"]["working_directory"]).resolve()),
        "kind": "test",
        "package-id": package_id,
        "package-name": PACKAGE,
        "status": "listed",
        "testcases": {
            record["name"]: {"filter-match": {"status": "matches"}, "ignored": record["ignored"], "kind": "test"}
            for record in records
        },
    }
    tests = {"rust-build-meta": build_meta, "rust-suites": {BINARY_ID: suite}, "test-count": len(records)}
    out = Path(args.output_dir)
    write_json(out / "cargo-metadata.json", cargo)
    write_json(out / "binaries-metadata.json", binaries)
    write_json(out / "tests-metadata.json", tests, sort_keys=False)


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
        "observed_test_cases": BASELINE_OBSERVED_CASES,
        "normalized_paths": {"workspace": "<WORKSPACE>", "target_directory": "<TARGET_DIR>", "rust_libdir": "<RUST_LIBDIR>"},
        "consumed_fields": ["package-id", "package-name", "binary-id", "binary-name", "kind", "binary-path", "cwd", "testcases", "platforms", "linked-paths", "build-script-out-dirs", "environment"],
    }
    write_json(out / "summary.json", summary)


def digest(args: argparse.Namespace) -> None:
    path = Path(args.path)
    h = hashlib.sha256(path.read_bytes()).hexdigest()
    print(h)


def stage_runtime(args: argparse.Namespace) -> None:
    result = validate_manifest(Path(args.manifest), Path(args.root), require_paths=False)
    resource_root = Path(args.resources).resolve()
    root = Path(args.root).resolve()
    for name in result["manifest"]["paths"]["runtime_inputs"]:
        source = rooted(resource_root, name, f"runtime resource {name}", must_exist=True)
        if source.is_symlink() or not source.is_file():
            die(f"declared runtime resource is not a regular file: {name}")
        destination = root / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)


def emit_environment(args: argparse.Namespace) -> None:
    manifest = validate_manifest(Path(args.manifest), Path(args.root), require_paths=True)["manifest"]
    for name, value in manifest["environment"].items():
        import shlex
        print(f"export {name}={shlex.quote(value)}")


def export_report(args: argparse.Namespace) -> None:
    source = Path(args.source)
    destination = Path(args.destination)
    if not destination.is_absolute():
        die("report destination must be absolute")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    directory_fd = os.open(os.sep, flags)
    temp_name: str | None = None
    try:
        for component in destination.parent.parts[1:]:
            next_fd = os.open(component, flags | nofollow, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = next_fd
        destination_name = destination.name
        try:
            existing = os.stat(destination_name, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        if existing is not None and not stat.S_ISREG(existing.st_mode):
            die("report destination must be a regular file when it exists")
        for attempt in range(100):
            candidate = f".{destination_name}.tmp.{os.getpid()}.{attempt}"
            try:
                temp_fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL | nofollow, 0o600, dir_fd=directory_fd)
            except FileExistsError:
                continue
            temp_name = candidate
            break
        else:
            die("could not create same-directory report temporary")
        with source.open("rb") as input_stream, os.fdopen(temp_fd, "wb") as output_stream:
            shutil.copyfileobj(input_stream, output_stream)
            output_stream.flush()
            os.fsync(output_stream.fileno())
        ready_marker = os.environ.get("BUCK2_NEXTEST_EXPORT_REPORT_READY")
        release_gate = os.environ.get("BUCK2_NEXTEST_EXPORT_REPORT_GATE")
        if ready_marker and release_gate:
            Path(ready_marker).write_text(temp_name + "\n", encoding="utf-8")
            while os.path.exists(release_gate):
                time.sleep(0.05)
        try:
            existing = os.stat(destination_name, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        if existing is not None and not stat.S_ISREG(existing.st_mode):
            die("report destination changed to a non-regular file")
        os.replace(temp_name, destination_name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        temp_name = None
    except (OSError, ValueError) as exc:
        die(f"could not atomically export JUnit report: {exc}")
    finally:
        if temp_name is not None:
            try:
                os.unlink(temp_name, dir_fd=directory_fd)
            except OSError:
                pass
        os.close(directory_fd)


GENERIC_SCHEMA_VERSION = 2
GENERIC_ID_PREFIX = "b2n1:"
_ID_UNRESERVED = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
_GENERIC_ENVIRONMENT_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z", re.ASCII)
_GENERIC_OWNER_LABEL = re.compile(r"//(?:[^/\s:]+/)*[^/\s]+(?::[^/\s]+)?\Z", re.ASCII)
_GENERIC_RESERVED_PATHS = frozenset(ADAPTER_OWNED_PATHS)
_GENERIC_RESERVED_ENVIRONMENT_NAMES = frozenset(RESERVED_ENVIRONMENT_NAMES)


def _generic_percent_encode(value: str) -> str:
    if not isinstance(value, str):
        die("semantic identity components must be strings")
    encoded = []
    for byte in value.encode("utf-8"):
        char = chr(byte)
        if char in _ID_UNRESERVED:
            encoded.append(char)
        else:
            encoded.append("%{:02X}".format(byte))
    return "".join(encoded)


def semantic_id(package_identity: str, owner_label: str, binary_identity: str) -> str:
    components = (package_identity, owner_label, binary_identity)
    if any(not isinstance(value, str) or not value for value in components):
        die("semantic identity components must be non-empty strings")
    return GENERIC_ID_PREFIX + ";".join(
        name + "=" + _generic_percent_encode(value)
        for name, value in zip(("p", "o", "b"), components)
    )


def decode_semantic_id(value: str) -> tuple[str, str, str]:
    if not isinstance(value, str) or not value.startswith(GENERIC_ID_PREFIX):
        die("semantic ID has an unsupported version or prefix")
    body = value[len(GENERIC_ID_PREFIX):]
    fields = body.split(";")
    if len(fields) != 3 or [field[:2] for field in fields] != ["p=", "o=", "b="]:
        die("semantic ID must contain exactly p, o, and b fields")
    decoded = []
    for field in fields:
        encoded = field[2:]
        if not encoded:
            die("semantic ID identity components must be non-empty")
        output = bytearray()
        index = 0
        while index < len(encoded):
            char = encoded[index]
            if char == "%":
                if index + 2 >= len(encoded) or not re.fullmatch(r"[0-9A-F]{2}", encoded[index + 1:index + 3]):
                    die("semantic ID contains an invalid or non-canonical escape")
                byte = int(encoded[index + 1:index + 3], 16)
                if chr(byte) in _ID_UNRESERVED:
                    die("semantic ID percent-encodes an unreserved byte")
                output.append(byte)
                index += 3
            else:
                if char not in _ID_UNRESERVED or ord(char) > 0x7F:
                    die("semantic ID contains an unsafe literal byte")
                output.append(ord(char))
                index += 1
        try:
            decoded.append(output.decode("utf-8"))
        except UnicodeDecodeError as exc:
            die(f"semantic ID contains invalid UTF-8: {exc}")
    result = tuple(decoded)
    if semantic_id(*result) != value:
        die("semantic ID is not in canonical form")
    return result


def _generic_safe_relative_path(value: Any, name: str) -> str:
    expect(value, str, name)
    if not value or value.startswith("/") or "\\" in value or "\x00" in value:
        die(f"{name} must be a normalized relative POSIX path")
    parts = PurePosixPath(value).parts
    if not parts or any(part in ("", ".", "..") for part in parts):
        die(f"{name} must be a normalized relative POSIX path")
    return value


def _generic_path_prefix(left: str, right: str) -> bool:
    return is_prefix(path_parts(left), path_parts(right)) or is_prefix(path_parts(right), path_parts(left))


def _generic_toml_safe_path(value: str, name: str) -> str:
    value = _generic_safe_relative_path(value, name)
    if '"' in value or any(char.isspace() and char != " " for char in value):
        die(f"{name} contains characters that cannot be represented safely in TOML")
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in value):
        die(f"{name} contains characters that cannot be represented safely in TOML")
    return value


def validate_generic_manifest(path: Path) -> dict[str, Any]:
    data = expect(strict_load(path), dict, "generic manifest")
    if set(data) != {"schema_version", "records"} or data["schema_version"] != GENERIC_SCHEMA_VERSION:
        die("generic manifest must have schema_version 2 and records")
    records = expect(data["records"], list, "generic manifest.records")
    if not records:
        die("generic manifest.records must not be empty")
    identities = set()
    executable_sources = set()
    destinations = {}
    destination_names = {}
    package_cwds = {}
    cwd_packages = {}
    normalized = []
    for index, record in enumerate(records):
        prefix = f"records[{index}]"
        if not isinstance(record, dict):
            die(f"{prefix} must be an object")
        required = {"package_identity", "owner_label", "binary_identity", "display_name", "target_kind", "executable", "runtime", "generated_outputs", "cwd", "platform"}
        if set(record) != required:
            die(f"{prefix} fields must be exactly {sorted(required)}; record-level environment is unsupported")
        package = expect(record["package_identity"], str, f"{prefix}.package_identity")
        owner = expect(record["owner_label"], str, f"{prefix}.owner_label")
        binary = expect(record["binary_identity"], str, f"{prefix}.binary_identity")
        display = expect(record["display_name"], str, f"{prefix}.display_name")
        kind = expect(record["target_kind"], str, f"{prefix}.target_kind")
        if not package or not owner or not binary or not display or not kind:
            die(f"{prefix} identity and display fields must be non-empty")
        if _GENERIC_OWNER_LABEL.fullmatch(owner) is None:
            die(f"{prefix}.owner_label must be a canonical Buck label")
        identity = (package, owner, binary)
        if identity in identities:
            die(f"duplicate semantic identity: {identity}")
        identities.add(identity)
        generated_id = semantic_id(*identity)
        executable = expect(record["executable"], dict, f"{prefix}.executable")
        if set(executable) != {"source", "destination", "kind"}:
            die(f"{prefix}.executable fields are invalid")
        source = _generic_safe_relative_path(executable["source"], f"{prefix}.executable.source")
        destination = _generic_safe_relative_path(executable["destination"], f"{prefix}.executable.destination")
        if executable["kind"] != "regular_file":
            die(f"{prefix}.executable must be a regular_file")
        if source in executable_sources:
            die(f"executable is attached to more than one record: {source}")
        executable_sources.add(source)
        paths = [(destination, f"{prefix}.executable.destination")]
        runtime = expect(record["runtime"], list, f"{prefix}.runtime")
        runtime_records = []
        for runtime_index, item in enumerate(runtime):
            item_name = f"{prefix}.runtime[{runtime_index}]"
            item = expect(item, dict, item_name)
            if set(item) != {"source", "destination", "kind"}:
                die(f"{item_name} fields are invalid")
            item_source = _generic_safe_relative_path(item["source"], f"{item_name}.source")
            item_destination = _generic_safe_relative_path(item["destination"], f"{item_name}.destination")
            if item["kind"] != "regular_file":
                die(f"{item_name} must be a regular_file; symlinks and trees are unsupported")
            if item_source in executable_sources:
                die(f"runtime source is also an executable: {item_source}")
            runtime_records.append({"source": item_source, "destination": item_destination, "kind": item["kind"]})
            paths.append((item_destination, item_name + ".destination"))
        generated = expect(record["generated_outputs"], list, f"{prefix}.generated_outputs")
        if generated:
            die(f"{prefix}.generated_outputs are unsupported until their timing is proven")
        cwd = _generic_toml_safe_path(record["cwd"], f"{prefix}.cwd")
        if package in package_cwds and package_cwds[package] != cwd:
            die(f"{prefix}.cwd conflicts with the package cwd")
        if package not in package_cwds:
            for other_package, other_cwd in package_cwds.items():
                if other_package != package and _generic_path_prefix(cwd, other_cwd):
                    die(f"{prefix}.cwd overlaps another package cwd")
            if cwd in cwd_packages and cwd_packages[cwd] != package:
                die(f"{prefix}.cwd maps to more than one package identity")
            cwd_packages[cwd] = package
        package_cwds[package] = cwd
        if any(other_package != package and _generic_path_prefix(cwd, path) for path, other_package in destinations.items()):
            die(f"{prefix}.cwd overlaps a destination from another package")
        for left_index, (left, left_name) in enumerate(paths):
            if left in destinations:
                die(f"duplicate destination {left}: {left_name} and {destination_names[left]}")
            if left in _GENERIC_RESERVED_PATHS or _generic_path_prefix(left, "manifest.json"):
                die(f"{left_name} conflicts with an adapter-owned path: {left}")
            if any(other_package != package and _generic_path_prefix(left, other_cwd) for other_package, other_cwd in package_cwds.items()):
                die(f"{left_name} overlaps a package cwd from another package")
            destinations[left] = package
            destination_names[left] = left_name
            for right, right_name in paths[:left_index]:
                if _generic_path_prefix(left, right):
                    die(f"path-prefix overlap between {left_name} and {right_name}")
        platform_identity = expect(record["platform"], str, f"{prefix}.platform")
        if not platform_identity or "\x00" in platform_identity or any(char.isspace() for char in platform_identity):
            die(f"{prefix}.platform must be a non-empty opaque identity without whitespace")
        normalized.append({
            "package_identity": package,
            "owner_label": owner,
            "binary_identity": binary,
            "display_name": display,
            "target_kind": kind,
            "id": generated_id,
            "executable": {"source": source, "destination": destination, "kind": executable["kind"]},
            "runtime": runtime_records,
            "generated_outputs": [],
            "cwd": cwd,
            "platform": platform_identity,
        })
    return {"schema_version": GENERIC_SCHEMA_VERSION, "records": normalized}


def generic_metadata(records: list[dict[str, Any]], workspace: Path, target: Path) -> dict[str, Any]:
    packages = {}
    suites = {}
    for record in records:
        package_id = semantic_id(record["package_identity"], record["owner_label"], "package")
        binary_id = record["id"]
        packages.setdefault(package_id, {"id": package_id, "name": record["package_identity"], "target_kind": record["target_kind"]})
        suites[binary_id] = {
            "binary-id": binary_id,
            "binary-name": record["display_name"],
            "binary-path": str(workspace / record["executable"]["destination"]),
            "build-platform": record["platform"],
            "cwd": str(workspace / record["cwd"]),
            "kind": record["target_kind"],
            "package-id": package_id,
            "package-name": record["package_identity"],
            "status": "listed",
            "testcases": {},
        }
    build_meta = {"target-directory": str(target), "platforms": {}}
    return {"schema_version": GENERIC_SCHEMA_VERSION, "packages": list(packages.values()), "binaries": suites, "tests": {"rust-build-meta": build_meta, "rust-suites": suites, "test-count": 0}}


def emit_generic_metadata(args: argparse.Namespace) -> None:
    manifest = validate_generic_manifest(Path(args.manifest))
    write_json(Path(args.output), generic_metadata(manifest["records"], Path(args.workspace).resolve(), Path(args.target).resolve()))


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("emit-manifest")
    p.add_argument("--output", required=True)
    p.add_argument("--artifact", required=True)
    p.add_argument("--runtime-input", required=True)
    p.add_argument("--runtime-source", required=True)
    p.add_argument("--runtime-environment", default="declared")
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
    p = sub.add_parser("emit-generic-metadata")
    p.add_argument("--manifest", required=True)
    p.add_argument("--workspace", required=True)
    p.add_argument("--target", required=True)
    p.add_argument("--output", required=True)
    p.set_defaults(func=emit_generic_metadata)
    p = sub.add_parser("decode-semantic-id")
    p.add_argument("value")
    p.set_defaults(func=lambda args: print(json.dumps(decode_semantic_id(args.value), ensure_ascii=False)))
    p = sub.add_parser("normalize-baseline")
    p.add_argument("--raw-dir", required=True)
    p.add_argument("--output-dir", required=True)
    p.set_defaults(func=normalize_baseline)
    p = sub.add_parser("digest")
    p.add_argument("path")
    p.set_defaults(func=digest)
    p = sub.add_parser("stage-runtime")
    p.add_argument("--manifest", required=True)
    p.add_argument("--root", required=True)
    p.add_argument("--resources", required=True)
    p.set_defaults(func=stage_runtime)
    p = sub.add_parser("emit-environment")
    p.add_argument("--manifest", required=True)
    p.add_argument("--root", required=True)
    p.set_defaults(func=emit_environment)
    p = sub.add_parser("export-report")
    p.add_argument("--source", required=True)
    p.add_argument("--destination", required=True)
    p.set_defaults(func=export_report)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
