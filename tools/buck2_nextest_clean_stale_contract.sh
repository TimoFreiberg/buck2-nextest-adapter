#!/usr/bin/env bash
set -euo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
script="$repo/buck2_nextest_clean_stale.sh"
root=$(mktemp -d "${TMPDIR:-/tmp}/buck-clean-contract.XXXXXX")
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/buck-out"/{v2,old,new,arbitrary}
for isolation in v2 old new; do
    printf '%s\n' 'Signature: 8a477f597d28d172789f06886806bc55' >"$root/buck-out/$isolation/CACHEDIR.TAG"
done
printf '%s\n' 'not Buck-owned' >"$root/buck-out/arbitrary/CACHEDIR.TAG"
# Give the fixture enough apparent size to require cleanup.
dd if=/dev/zero of="$root/buck-out/old/payload" bs=1024 count=16 >/dev/null
# Make old sort before new on both BSD and GNU ls.
touch -t 202001010000 "$root/buck-out/old" "$root/buck-out/old/CACHEDIR.TAG"
touch -t 202101010000 "$root/buck-out/new" "$root/buck-out/new/CACHEDIR.TAG"
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
PATH="$shim:$PATH" run >/dev/null
! grep -F -- "$root/buck-out/v2" "$action_log"
! grep -F -- "$root/buck-out/arbitrary" "$action_log"
grep -F -- '--isolation-dir old clean' "$action_log"
test -d "$root/buck-out/v2"
test -d "$root/buck-out/arbitrary"
! test -d "$root/buck-out/old"
test -d "$root/buck-out/new"

for target in 4 11; do
    if BUCK_CLEAN_TARGET_GIB="$target" BUCK_CLEAN_PROJECT_ROOT="$root" BUCK2="$fake_buck" "$script" >/dev/null 2>&1; then
        printf 'invalid target unexpectedly accepted: %s\n' "$target" >&2
        exit 1
    fi
done
BUCK_CLEAN_TARGET_GIB=10 BUCK_CLEAN_PROJECT_ROOT="$root" BUCK2="$fake_buck" "$script" >/dev/null
printf '%s\n' 'buck cleanup contract: passed'
