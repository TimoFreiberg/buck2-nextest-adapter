#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-.}
artifact=$1
manifest=$2
validator=$3
cargo_baseline=$4
binary_baseline=$5
tests_baseline=$6
recorder=$root/nextest_test_recorder.py
[ -f "$recorder" ] || recorder="$root/../nextest_test_recorder.py"
recorder=$(cd "$(dirname "$recorder")" && pwd -P)/$(basename "$recorder")
tmp=$(mktemp -d "./.buck2-nextest-concurrent.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
python3 - "$root/adapter.sh" "$recorder" "$artifact" "$manifest" "$validator" "$cargo_baseline" "$binary_baseline" "$tests_baseline" "$tmp" <<'PY'
import os
import subprocess
import sys
from pathlib import Path

adapter, recorder, artifact, manifest, validator, cargo_baseline, binary_baseline, tests_baseline, tmp = sys.argv[1:]
base = [adapter, "buck-artifact", "--build-mode", "--artifact", artifact, "--manifest", manifest, "--validator", validator, "--cargo-baseline", cargo_baseline, "--binary-baseline", binary_baseline, "--tests-baseline", tests_baseline, "--runtime-resource", os.path.join(os.path.dirname(adapter), "runtime/buck2_artifact_runtime.txt"), "--source-denial", os.path.join(os.path.dirname(adapter), "tools/cargo_source_denial.sh"), "--cargo-command", os.path.join(os.path.dirname(adapter), "tools/cargo_source_denial.sh"), "--python-command", "python3", "--cargo-nextest-command", recorder, "nextest"]
cases = [("alpha", "test(=pass_case)"), ("beta", "test(=pass_case) && name ~ beta")]
processes = []
try:
    for profile, filterset in cases:
        report = os.path.join(tmp, profile + ".xml")
        env = os.environ.copy()
        env["BUCK2_NEXTEST_ARGV_LOG"] = os.path.join(tmp, profile + ".argv")
        command = base + ["--junit-report", report, "--profile", profile, "--filter", filterset, "--no-tests", "auto", "--report-skipped", "default", "--timeout-seconds", "0"]
        output = open(os.path.join(tmp, profile + ".out"), "wb")
        processes.append((subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, env=env), output, report, profile, filterset))
    for process, output, report, profile, filterset in processes:
        process.communicate(timeout=30)
        status = process.returncode
        output.close()
        assert status == 0, (profile, status, Path(output.name).read_text())
        assert Path(report).is_file()
        assert 'name="pass_case"' in Path(report).read_text()
        text = Path(output.name).read_text()
        assert text.count("cleanup=once") == 1
        root_line = next(line for line in text.splitlines() if "cleanup=once root=" in line)
        assert not Path(root_line.split("cleanup=once root=", 1)[1]).exists()
finally:
    for process, output, *_ in processes:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
        output.close()
for profile, filterset in cases:
    argv = Path(tmp, profile + ".argv").read_text()
    assert filterset in argv
assert not Path(tmp, "junit.xml").exists()
PY
printf '%s\n' 'configured concurrent runs: passed'
