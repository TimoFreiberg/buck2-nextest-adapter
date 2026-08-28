#!/usr/bin/env bash
set -euo pipefail

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
script="$repo/buck2_nextest_clean_stale.sh"
root=$(mktemp -d "${TMPDIR:-/tmp}/buck-clean-contract.XXXXXX")
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/buck-out"/{v2,z-old,a-new,z-invalid,z-symlink}
make_cache() {
    local isolation=$1
    mkdir -p "$root/buck-out/$isolation"/{cache,art,log}
    printf '%s\n' 'Signature: 8a477f597d28d172789f06886806bc55' >"$root/buck-out/$isolation/CACHEDIR.TAG"
}
for isolation in v2 z-old a-new; do
    make_cache "$isolation"
done
printf '%s\n' 'not Buck-owned' >"$root/buck-out/z-invalid/CACHEDIR.TAG"
mkdir -p "$root/buck-out/z-invalid"/{cache,art,log}
printf '%s\n' 'Signature: 8a477f597d28d172789f06886806bc55' >"$root/buck-out/z-symlink/CACHEDIR.TAG"
mkdir -p "$root/buck-out/z-symlink"/{art,log} "$root/outside"
ln -s "$root/outside" "$root/buck-out/z-symlink/cache"
touch -t 202006010000 "$root/buck-out/z-symlink" "$root/buck-out/z-symlink/CACHEDIR.TAG"
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
# Use a nonexistent PID so the fixture exercises the lsof fallback rather than
# depending on the host process table or the fixture shell's working directory.
daemon_pid=999999999
ps_shim="$root/ps"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$BUCK_CLEAN_DAEMON_PID buck2d[fixture] --isolation-dir ${BUCK_CLEAN_DAEMON_ISOLATION:-z-old} daemon"' >"$ps_shim"
chmod +x "$ps_shim"
lsof_shim="$root/lsof"
printf '%s\n' '#!/usr/bin/env bash' 'printf "n%s\\n" "$(CDPATH= cd -- "${BUCK_CLEAN_DAEMON_CWD:-$BUCK_CLEAN_PROJECT_ROOT}" && pwd -P)"' >"$lsof_shim"
chmod +x "$lsof_shim"
export BUCK_CLEAN_DAEMON_PID="$daemon_pid"
PATH="$root:$shim:$PATH" run >/dev/null
! grep -F -- "$root/buck-out/v2" "$action_log"
! grep -F -- "$root/buck-out/z-invalid" "$action_log"
! grep -F -- '--isolation-dir z-symlink clean' "$action_log"
grep -F -- '--isolation-dir a-new clean' "$action_log"
! grep -F -- '--isolation-dir z-old clean' "$action_log"
test -d "$root/buck-out/v2"
test -d "$root/buck-out/z-invalid"
test -d "$root/buck-out/z-old"
! test -d "$root/buck-out/a-new"

# A daemon whose cwd is exactly its isolation directory is protected.
make_cache z-old-exact
touch -t 202001010000 "$root/buck-out/z-old-exact" "$root/buck-out/z-old-exact/CACHEDIR.TAG"
: >"$root/old-present"
BUCK_CLEAN_DAEMON_ISOLATION=z-old-exact BUCK_CLEAN_DAEMON_CWD="$root/buck-out/z-old-exact" PATH="$root:$shim:$PATH" run >/dev/null
! grep -F -- '--isolation-dir z-old-exact clean' "$action_log"
test -d "$root/buck-out/z-old-exact"

# A daemon below its isolation directory is protected too.
make_cache z-old-descendant
mkdir "$root/buck-out/z-old-descendant/worker"
touch -t 202001010000 "$root/buck-out/z-old-descendant" "$root/buck-out/z-old-descendant/CACHEDIR.TAG"
: >"$root/old-present"
BUCK_CLEAN_DAEMON_ISOLATION=z-old-descendant BUCK_CLEAN_DAEMON_CWD="$root/buck-out/z-old-descendant/worker" PATH="$root:$shim:$PATH" run >/dev/null
! grep -F -- '--isolation-dir z-old-descendant clean' "$action_log"
test -d "$root/buck-out/z-old-descendant"

# A similarly prefixed sibling is outside the protected path boundary.
make_cache z-old-sibling
touch -t 202001010000 "$root/buck-out/z-old-sibling" "$root/buck-out/z-old-sibling/CACHEDIR.TAG"
: >"$root/old-present"
foreign_root=$(mktemp -d "${TMPDIR:-/tmp}/buck-clean-foreign.XXXXXX")
mkdir "$foreign_root/z-old-sibling-extra"
BUCK_CLEAN_DAEMON_ISOLATION=z-old-sibling BUCK_CLEAN_DAEMON_CWD="$foreign_root/z-old-sibling-extra" PATH="$root:$shim:$PATH" run >/dev/null
rm -rf "$foreign_root"
grep -F -- '--isolation-dir z-old-sibling clean' "$action_log"
! test -d "$root/buck-out/z-old-sibling"

for target in 4 11; do
    if BUCK_CLEAN_TARGET_GIB="$target" BUCK_CLEAN_PROJECT_ROOT="$root" BUCK2="$fake_buck" "$script" >/dev/null 2>&1; then
        printf 'invalid target unexpectedly accepted: %s\n' "$target" >&2
        exit 1
    fi
done
BUCK_CLEAN_TARGET_GIB=10 BUCK_CLEAN_PROJECT_ROOT="$root" BUCK2="$fake_buck" "$script" >/dev/null

symlink_root=$(mktemp -d "${TMPDIR:-/tmp}/buck-clean-symlink.XXXXXX")
trap 'rm -rf "$root" "$symlink_root"' EXIT
mkdir -p "$symlink_root/real-buck-out"
ln -s "$symlink_root/real-buck-out" "$symlink_root/buck-out"
if BUCK_CLEAN_PROJECT_ROOT="$symlink_root" BUCK2="$fake_buck" "$script" >/dev/null 2>&1; then
    printf '%s\n' 'symlinked buck-out unexpectedly accepted' >&2
    exit 1
fi

fail_ps="$root/fail-ps"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$fail_ps"
chmod +x "$fail_ps"
fail_bin="$root/fail-bin"
mkdir "$fail_bin"
ln -s "$fail_ps" "$fail_bin/ps"
: >"$root/old-present"
if PATH="$fail_bin:$shim:$PATH" BUCK_CLEAN_TARGET_GIB=5 BUCK_CLEAN_PROJECT_ROOT="$root" BUCK2="$fake_buck" "$script" >/dev/null 2>&1; then
    printf '%s\n' 'failed ps unexpectedly accepted' >&2
    exit 1
fi
printf '%s\n' 'buck cleanup contract: passed'
