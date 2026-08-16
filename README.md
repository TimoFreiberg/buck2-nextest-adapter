# Buck2/nextest artifact handoff

This repository proves the first local Buck2/nextest artifact boundary. Buck2
builds one native `rust_test` executable, emits a versioned serialized manifest,
and a POSIX adapter stages that declared output for documented nextest metadata
reuse. The original Cargo fixture remains as a separate legacy regression path.

## Prerequisites

Run on a Unix-like host with these tools already installed and available on
`PATH`:

- `buck2` with the bundled prelude native `rust_test` rule;
- Rust/Cargo (`rustc` and `cargo`);
- Cargo 1.78 or newer (the checked-in lockfile uses format 4);
- `cargo-nextest` 0.9.143 in the captured environment, exposing
  `--cargo-metadata`, `--binaries-metadata`, `--target-dir-remap`,
  `--workspace-remap`, `--build-dir-remap`, and `--filterset`;
- Python 3 for baseline, manifest, and scenario development/test tooling.

No toolchain provisioning is included. The legacy adapter sets
`CARGO_NET_OFFLINE=true`; the Buck artifact path does not run Cargo build/test
to produce its executable. `setsid` (or an equivalent process-group launcher)
is required only by the signal-cleanup scenario. The current macOS host does
not provide `setsid` on `PATH`, so that lifecycle scenario reports a concrete
prerequisite blocker rather than silently claiming descendant cleanup.

## Legacy Cargo-fixture regression

```sh
buck2 test --test-executor-stdout=- --test-executor-stderr=- //:nextest_spike
```

This retains the original Cargo-owned behavior and is intentionally not used
to prove the Buck artifact handoff.

## Buck2-built artifact handoff

```sh
buck2 build //:buck2_nextest_rust_test //:buck2_nextest_artifact_manifest
buck2 test --test-executor-stdout=- --test-executor-stderr=- //:nextest_buck_artifact
```

The native target is one executable with `pass_case` and `fail_case`. The
adapter consumes its declared Buck output, validates the manifest before the
nextest marker, computes matching SHA-256 digests for the Buck output and
staged executable, synthesizes Cargo-shaped metadata, and invokes:

```text
cargo nextest list --cargo-metadata ... --binaries-metadata ... \
  --target-dir-remap ... --workspace-remap ... --build-dir-remap ...
cargo nextest run --filterset test(=pass_case) [the same metadata/remaps]
```

The expected failure is isolated so the default target remains green:

```sh
set +e
buck2 test --test-executor-stdout=- --test-executor-stderr=- //:nextest_buck_artifact_expected_failure
status=$?
set -e
[ "$status" -ne 0 ]
```

The checked-in fixture is moved aside and inaccessible for the private lifetime
of the Buck artifact path; its two Cargo integration binaries are baseline
observations mapped to one synthetic Buck identity, `buck2-nextest-buck-artifact` /
`buck2_nextest_rust_test`, of kind `test`.

## Baseline and manifest contract

Capture the installed baseline in an isolated temporary root:

```sh
CARGO_NET_OFFLINE=true ./tools/capture_cargo_nextest_baseline.sh baseline/normalized
```

The command records Cargo metadata, nextest binary-only and test-list JSON,
exact tool versions, target/platform information, and a checked-in fixture
digest. Paths are normalized to `<WORKSPACE>` and `<TARGET_DIR>` in the
checked-in baseline; host-specific Rust libdir values are observations, not
portable contract paths.

`artifact-manifest.example.json` documents manifest schema version 1. It
contains exactly one package/binary identity, both test names, rooted relative
executable/working-directory/runtime paths, declared environment, target
triple/features, and generated outputs. `tools/nextest_artifact.py` rejects
duplicate JSON keys, wrong types, missing/unknown fields or versions, absolute
and traversal paths, symlinks, and missing staged entries before nextest runs.
See [`docs/baseline-and-manifest.md`](docs/baseline-and-manifest.md) for the
field inventory, compatibility policy, and official nextest references.

## Scope boundary

This feasibility step proves only local discovery/listing and one filtered run
of a Buck2-built artifact through the installed nextest CLI. Retries, timeouts,
groups, JUnit/status mapping, remote-like or remote execution, direct nextest
embedding, native provider promotion, and richer event protocols remain
unproven and are deliberately deferred. Human-readable nextest output remains
diagnostic rather than a protocol.

## Resource-contract probe

The original resource-contract probe remains available for the legacy fixture:

```sh
buck2 test --test-executor-stdout=- --test-executor-stderr=- //:nextest_spike_probe
```

It prints its resolved executable, project/resource roots, working directory,
and each declared fixture resource after reading it. The Buck artifact scenario
is the contract check for the new manifest and native executable.

This Buck2 release uses `--test-executor-stdout=- --test-executor-stderr=-`
to stream test output; older releases may spell the same operation
`--show-output`.

To verify failure propagation without making the default command fail, use an
isolated shell assertion. The fixture files must remain unchanged:

```sh
set -eu
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' 0
before="$check_dir/before"
after="$check_dir/after"
out="$check_dir/expected-failure.out"
shasum fixture/Cargo.toml fixture/Cargo.lock fixture/src/lib.rs \
  fixture/tests/pass_case.rs fixture/tests/fail_case.rs >"$before"
set +e
buck2 test --test-executor-stdout=- --test-executor-stderr=- //:nextest_spike_expected_failure >"$out" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
grep -F 'buck2-nextest-adapter: scenario=fail' "$out"
grep -F 'buck2-nextest-adapter: exec cargo nextest run --manifest-path' "$out"
grep -F -- '--locked --filterset test(=fail_case)' "$out"
grep -F 'buck2-nextest-fixture: fail-test' "$out"
shasum fixture/Cargo.toml fixture/Cargo.lock fixture/src/lib.rs \
  fixture/tests/pass_case.rs fixture/tests/fail_case.rs >"$after"
cmp "$before" "$after"
```

The captured pass output should contain `scenario=pass`, the `pass_case`
filterset, and the manifest identifier. It should not contain `scenario=fail`
or `buck2-nextest-fixture: fail-test`; nextest normally suppresses successful
test stdout, so the adapter marker and exit status are the green-path contract.
The captured expected-failure output should contain the corresponding fail
markers and `buck2-nextest-fixture: fail-test`. Human-readable nextest output is
diagnostic only and is not parsed as a protocol.

## Adapter validation

The legacy adapter interface is `adapter.sh cargo-fixture [--manifest-path PATH]
[--scenario pass|fail]`. Buck artifact runs use `adapter.sh buck-artifact` with
one declared artifact, manifest, validator, and three baseline metadata files;
they reject fixture resources and `--manifest-path`.

It defaults to the fixture manifest and the `pass` scenario. These checks must
all fail before printing an `exec cargo nextest run` marker:

```sh
set -eu
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' 0
set +e
./adapter.sh --scenario invalid >"$check_dir/invalid.out" 2>&1
s1=$?
./adapter.sh --unknown-option >"$check_dir/unknown.out" 2>&1
s2=$?
./adapter.sh --manifest-path fixture/missing-Cargo.toml >"$check_dir/missing.out" 2>&1
s3=$?
PATH=/usr/bin:/bin ./adapter.sh >"$check_dir/missing-cargo.out" 2>&1
s4=$?
set -e
[ "$s1" -ne 0 ] && [ "$s2" -ne 0 ] && [ "$s3" -ne 0 ] && [ "$s4" -ne 0 ]
grep -F 'invalid scenario' "$check_dir/invalid.out"
grep -F 'unknown option' "$check_dir/unknown.out"
grep -F 'manifest does not exist' "$check_dir/missing.out"
grep -F 'cargo is not available on PATH' "$check_dir/missing-cargo.out"
! grep -F 'exec cargo nextest run' "$check_dir/invalid.out" "$check_dir/unknown.out" "$check_dir/missing.out" "$check_dir/missing-cargo.out"
```

The controlled missing-tool check assumes `/bin/sh` is available to run the
script while the Cargo installation directory is excluded from `PATH`.

## Follow-up design question

The next iteration should replace Cargo-owned discovery with Buck2-provided test
identity, artifact, and runtime metadata, then reassess whether the ordinary
nextest CLI remains sufficient. That work must separately address Buck2-built
artifacts, runtime dependencies and paths, remote execution, and result
mapping. This spike intentionally does not claim any of those behaviors.
