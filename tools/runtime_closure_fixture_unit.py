#!/usr/bin/env python3
"""Check that the resource fixture's positive and negative binaries differ only in closure."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


def run(binary: str) -> tuple[int, str]:
    result = subprocess.run([binary, "--exact", "provider_runtime_resource_case", "--nocapture"], text=True, capture_output=True)
    return result.returncode, result.stdout + result.stderr


def main() -> int:
    positive, negative = sys.argv[1:]
    status, output = run(positive)
    if status != 0 or "runtime resource=ok" not in output:
        print(output, file=sys.stderr)
        return 1
    status, output = run(negative)
    if status == 0 or "buck2-nextest runtime closure missing generated resource" not in output:
        print(output, file=sys.stderr)
        return 1
    print("runtime closure fixture unit: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
