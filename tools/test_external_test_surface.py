#!/usr/bin/env python3
"""Observable shape checks for the pinned Buck external test surface."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    rule = (ROOT / "nextest.bzl").read_text(encoding="utf-8")
    buck = (ROOT / "BUCK").read_text(encoding="utf-8")
    required = [
        "ExternalRunnerTestInfo(",
        "run_from_project_root = True",
        "use_project_relative_paths = True",
        "supports_test_execution_caching = False",
        "NextestBuckTestBinaryInfo",
        "nextest_buck_test_binary",
        "nextest_buck_test(",
        "name = \"nextest_buck_test_generic_multi_binary\"",
    ]
    missing = [value for value in required if value not in rule and value not in buck]
    if missing:
        raise SystemExit("production external test surface is incomplete: " + ", ".join(missing))
    production_rule = rule.split("def _nextest_buck_test_impl", 1)[1].split("def _nextest_executable_impl", 1)[0]
    if "InternalRunnerTestInfo" in production_rule or "cargo" in production_rule or "rustc" in production_rule:
        raise SystemExit("production rule violates the Buck/nextest ownership boundary")
    print("external test surface contract passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
