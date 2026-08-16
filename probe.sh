#!/bin/sh
set -eu

project_root=${BUCK_PROJECT_ROOT:?BUCK_PROJECT_ROOT is not set}
resource_root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-$project_root}
[ -d "$resource_root" ]
printf 'buck2-nextest-probe: executable=%s\n' "$0"
printf 'buck2-nextest-probe: project-root=%s\n' "$project_root"
printf 'buck2-nextest-probe: resource-root=%s\n' "$resource_root"
printf 'buck2-nextest-probe: working-directory=%s\n' "$(pwd)"

for resource in fixture/Cargo.toml fixture/Cargo.lock fixture/src/lib.rs fixture/tests/pass_case.rs fixture/tests/fail_case.rs; do
    path="$resource_root/$resource"
    printf 'buck2-nextest-probe: resource=%s path=%s\n' "$resource" "$path"
    [ -r "$path" ]
    printf 'buck2-nextest-probe: read=%s\n' "$resource"
    case "$resource" in
        fixture/Cargo.toml) grep -F '[package]' "$path" >/dev/null ;;
        fixture/Cargo.lock) grep -F 'version = 4' "$path" >/dev/null ;;
        fixture/src/lib.rs) grep -F 'Cargo fixture' "$path" >/dev/null ;;
        fixture/tests/pass_case.rs) grep -F 'buck2-nextest-fixture: pass-test' "$path" >/dev/null ;;
        fixture/tests/fail_case.rs) grep -F 'buck2-nextest-fixture: fail-test' "$path" >/dev/null ;;
    esac
done
