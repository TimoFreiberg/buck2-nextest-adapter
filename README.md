# Buck2/nextest spike

This repository contains a smallest-useful local Buck2/nextest harness. It is
intentionally a **Cargo-owned fixture stand-in**: Buck2 supervises an adapter,
but the adapter still lets Cargo and nextest discover and build the checked-in
fixture. This does not establish that nextest can discover or run a Buck2-built
artifact, remove Cargo from discovery, or work with remote execution.

## Prerequisites

Run on a Unix-like host with these tools already installed and available on
`PATH`:

- `buck2`
- Rust/Cargo (`rustc` and `cargo`)
- Cargo 1.78 or newer (the checked-in lockfile uses format 4)
- `cargo-nextest` with `cargo nextest run --help` exposing `--filterset`

No toolchain provisioning is included in this spike. The adapter sets
`CARGO_NET_OFFLINE=true`, uses the locked dependency-free fixture, and places
all Cargo build output in a temporary directory removed on exit.

## Buck2 checks

The normal green target is deliberately separate from the negative check:

```sh
buck2 test --test-executor-stdout=- --test-executor-stderr=- //:nextest_spike
```

This Buck2 release uses `--test-executor-stdout=- --test-executor-stderr=-`
to stream test output; older releases may spell the same operation
`--show-output`.

The adapter should print markers including:

```text
buck2-nextest-adapter: scenario=pass manifest=...
buck2-nextest-adapter: exec cargo nextest run --manifest-path ... --locked --filterset test(=pass_case)
```

The normal command names only `//:nextest_spike`; it does not run the expected
failure target. The required resource-contract probe can be run independently:

```sh
buck2 test --test-executor-stdout=- --test-executor-stderr=- //:nextest_spike_probe
```

The probe prints its resolved executable, project/resource roots, working
directory, and each declared fixture resource after reading it.

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

The adapter's narrow interface is:

```text
adapter.sh [--manifest-path PATH] [--scenario pass|fail]
```

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
