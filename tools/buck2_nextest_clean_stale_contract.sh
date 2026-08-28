#!/usr/bin/env bash
set -euo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
script="$repo/buck2_nextest_clean_stale.sh"
root=$(mktemp -d "${TMPDIR:-/tmp}/buck-clean-contract.XXXXXX")
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/buck-out"/{v2,z-old,a-new,z-invalid}
for isolation in v2 z-old a-new; do
    printf '%s\n' 'Signature: 8a477f597d28d172789f06886806bc55' >"$root/buck-out/$isolation/CACHEDIR.TAG"
    mkdir -p "$root/buck-out/$isolation"/{cache,art,log}
done
printf '%s\n' 'not Buck-owned' >"$root/buck-out/z-invalid/CACHEDIR.TAG"
mkdir -p "$root/buck-out/z-invalid"/{cache,art,log}
# Give the fixture enough apparent size to require cleanup.
dd if=/dev/zero of="$root/buck-out/z-old/payload" bs=1024 count=16 >/dev/null
# z-old is older than a-new despite sorting later lexically.
touch -t 202001010000 "$root/buck-out/z-old" "$root/buck-out/z-old/CACHEDIR.TAG"
touch -t 202101010000 "$root/buck-out/a-new" "$root/buck-out/a-new/CACHEDIR.TAG"
touch -t 201901010000 "$root/buck-out/z-invalid" "$root/buck-out/z-invalid/CACHEDIR.TAG"
: >"$root/old-present"

action_log="$root/actions"
fake_buck="$root/fake-buck"
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'printf "%s\\n" "$*" >>"$BUCK_CLEAN_ACTION_LOG"' 'isolation=' 'previous=' 'for arg in "$@"; do if [[ $previous == --isolation-dir ]]; then isolation=$arg; fi; previous=$arg; done' 'rm -rf "$BUCK_CLEAN_PROJECT_ROOT/buck-out/$isolation"' 'rm -f "$BUCK_CLEAN_PROJECT_ROOT/old-present"' >"$fake_buck"
chmod +x "$fake_buck"

run() {
    BUCK_CLEAN_PROJECT_ROOT="$root" BUCK_CLEAN_ACTION_LOG="$action_log" BUCK_CLEAN_TARGET_GIB=5 BUCK_CLEAN_PARALLELISM=1 BUCK2="$fake_buck" "$script"
}
# The fixture is smaller than 5 GiB, so add a deterministic fake du shim.
shim="$root/bin"; mkdir "$shim"
printf '%s\n' '#!/usr/bin/env bash' 'if [[ $1 == -sk && $2 == *buck-out ]]; then if [[ -f "$BUCK_CLEAN_PROJECT_ROOT/old-present" ]]; then echo "6291457 $2"; else echo "4194304 $2"; fi; elif [[ $1 == -sk ]]; then echo "6291456 $2"; else exec /usr/bin/du "$@"; fi' >"$shim/du"
chmod +x "$shim/du"
ps_shim="$root/ps"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "buck2d[fixture] --isolation-dir z-old daemon"' >"$ps_shim"
chmod +x "$ps_shim"
PATH="$root:$shim:$PATH" run >/dev/null
! grep -F -- "$root/buck-out/v2" "$action_log"
! grep -F -- "$root/buck-out/z-invalid" "$action_log"
grep -F -- '--isolation-dir a-new clean' "$action_log"
! grep -F -- '--isolation-dir z-old clean' "$action_log"
test -d "$root/buck-out/v2"
test -d "$root/buck-out/z-invalid"
test -d "$root/buck-out/z-old"
! test -d "$root/buck-out/a-new"

for target in 4 11; do
    if BUCK_CLEAN_TARGET_GIB="$target" BUCK_CLEAN_PROJECT_ROOT="$root" BUCK2="$fake_buck" "$script" >/dev/null 2>&1; then
        printf 'invalid target unexpectedly accepted: %s\n' "$target" >&2
        exit 1
    fi
done
BUCK_CLEAN_TARGET_GIB=10 BUCK_CLEAN_PROJECT_ROOT="$root" BUCK2="$fake_buck" "$script" >/dev/null
printf '%s\n' 'buck cleanup contract: passed'
