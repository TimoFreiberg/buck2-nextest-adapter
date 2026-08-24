#!/usr/bin/env python3
"""Validate the declared generic Buck/nextest test contract.

This is deliberately a contract fixture, not a nextest runner. The production
rule hands one suite to a future adapter; this executable proves that Buck
supplies a declared manifest and that validation happens before dispatch.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--record-count", required=True, type=int)
    parser.add_argument("--declared-input", action="append", default=[])
    args = parser.parse_args()
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import nextest_artifact

    manifest = nextest_artifact.validate_generic_manifest(Path(args.manifest))
    declared = [Path(value) for value in args.declared_input]
    if not declared:
        print("nextest contract: no declared provider inputs", file=sys.stderr)
        return 2
    for path in declared:
        if path.is_symlink() or not path.is_file():
            print(f"nextest contract: declared provider input is not a regular file: {path}", file=sys.stderr)
            return 2
    if len(manifest["records"]) != args.record_count:
        print(
            f"nextest contract: expected {args.record_count} records, got {len(manifest['records'])}",
            file=sys.stderr,
        )
        return 2
    print("buck2-nextest-contract: provider=NextestBuckTestBinaryInfo")
    print(f"buck2-nextest-contract: records={len(manifest['records'])}")
    print("buck2-nextest-contract: dispatch=deferred-nextest-suite")
    print(json.dumps([record["id"] for record in manifest["records"]], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
