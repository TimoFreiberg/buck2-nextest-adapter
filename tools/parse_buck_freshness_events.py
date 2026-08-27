#!/usr/bin/env python3
"""Fail-closed parser for the production test freshness evidence contract."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


def parse(path: Path, target: str, require_execution: bool = True) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SystemExit(f"freshness evidence is not valid JSON: {exc}")
    if not isinstance(value, dict) or set(value) != {"target", "events"}:
        raise SystemExit("freshness evidence must contain exactly target and events")
    if value["target"] != target:
        raise SystemExit("freshness evidence target identity does not match invocation")
    events = value["events"]
    if not isinstance(events, list):
        raise SystemExit("freshness events must be a list")
    supported = {"action_execution", "cache_hit", "test_result_hit"}
    if any(not isinstance(event, str) or event not in supported for event in events):
        raise SystemExit("freshness evidence contains an unsupported event")
    if len(set(events)) != len(events):
        raise SystemExit("freshness evidence contains ambiguous duplicate events")
    if require_execution and "action_execution" not in events:
        raise SystemExit("freshness evidence is missing an authoritative action execution event")
    if "cache_hit" in events or "test_result_hit" in events:
        raise SystemExit("freshness evidence contains cache or test-result reuse")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--target", required=True)
    args = parser.parse_args()
    parse(args.path, args.target)
    print(f"freshness evidence valid: {args.target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
