#!/usr/bin/env bash
set -euo pipefail

project_root=${BUCK_CLEAN_PROJECT_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)}
buck_out="$project_root/buck-out"
buck=${BUCK2:-buck2}
target_gib=${BUCK_CLEAN_TARGET_GIB:-8}
parallelism=${BUCK_CLEAN_PARALLELISM:-8}

case "$target_gib" in
    5|6|7|8|9|10) ;;
    *) printf '%s\n' 'BUCK_CLEAN_TARGET_GIB must be an integer from 5 through 10' >&2; exit 2 ;;
esac
case "$parallelism" in
    ''|*[!0-9]*) printf '%s\n' 'BUCK_CLEAN_PARALLELISM must be an integer from 1 through 16' >&2; exit 2 ;;
esac
if (( parallelism < 1 || parallelism > 16 )); then
    printf '%s\n' 'BUCK_CLEAN_PARALLELISM must be an integer from 1 through 16' >&2
    exit 2
fi

if [[ ! -d "$buck_out" ]]; then
    printf '%s\n' 'buck-out does not exist'
    exit 0
fi
if [[ -L "$buck_out" ]]; then
    printf '%s\n' 'refusing to clean a symlinked buck-out' >&2
    exit 2
fi

target_kib=$((target_gib * 1024 * 1024))
out_kib=$(du -sk "$buck_out" | awk '{print $1}')
printf 'buck-out=%s GiB target=%s GiB\n' "$((out_kib / 1024 / 1024))" "$target_gib"
if (( out_kib <= target_kib )); then
    printf '%s\n' 'nothing to clean'
    exit 0
fi

active_isolation() {
    local isolation=$1
    local process_listing
    process_listing=$(command ps ax -o command=) || {
        printf '%s\n' 'unable to inspect Buck daemons; refusing destructive cleanup' >&2
        exit 2
    }
    awk -v wanted="$isolation" '
        /buck2d\[/ {
            for (i = 1; i < NF; i++) {
                if ($i == "--isolation-dir" && $(i + 1) == wanted) found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    ' <<< "$process_listing"
}

# ls is used only for Buck-generated isolation names, which are validated below.
# Unlike stat -f, this ordering form works on both BSD and GNU userlands.
ordered_paths=$(ls -1dtr "$buck_out"/*/ 2>/dev/null || true)
needed_kib=$((out_kib - target_kib))
selected=()
selected_kib=0
while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ -d "$path" && ! -L "$path" ]] || continue
    [[ "$path" == "$buck_out"/*/ ]] || continue
    isolation=${path#"$buck_out"/}
    isolation=${isolation%/}
    [[ "$isolation" != v2 ]] || continue
    case "$isolation" in
        [A-Za-z0-9][A-Za-z0-9_-]*) ;;
        *) continue ;;
    esac
    tag="$path/CACHEDIR.TAG"
    [[ -f "$tag" && ! -L "$tag" ]] || continue
    grep -Fq 'Signature: 8a477f597d28d172789f06886806bc55' "$tag" || continue
    [[ -d "$path/cache" && -d "$path/art" && -d "$path/log" ]] || continue
    if active_isolation "$isolation"; then
        printf 'skip active isolation=%s\n' "$isolation" >&2
        continue
    fi
    size_kib=$(du -sk "$path" | awk '{print $1}')
    selected+=("$isolation")
    selected_kib=$((selected_kib + size_kib))
    if (( selected_kib >= needed_kib )); then break; fi
done <<< "$ordered_paths"

if ((${#selected[@]} == 0)); then
    printf '%s\n' 'no Buck-owned inactive custom isolation caches available' >&2
    exit 1
fi
printf 'selected=%s reclaimable=%s GiB parallelism=%s\n' \
    "${#selected[@]}" "$((selected_kib / 1024 / 1024))" "$parallelism"

pids=()
run_batch() {
    local status=0 pid
    for pid in "${pids[@]}"; do
        wait "$pid" || status=1
    done
    pids=()
    return "$status"
}

for isolation in "${selected[@]}"; do
    if active_isolation "$isolation"; then
        printf 'skip active isolation=%s\n' "$isolation" >&2
        continue
    fi
    printf 'clean isolation=%s\n' "$isolation"
    "$buck" --isolation-dir "$isolation" clean &
    pids+=("$!")
    if ((${#pids[@]} >= parallelism)); then
        run_batch
    fi
done
if ((${#pids[@]} > 0)); then run_batch; fi

out_kib=$(du -sk "$buck_out" | awk '{print $1}')
printf 'buck-out-final=%s GiB target=%s GiB\n' "$((out_kib / 1024 / 1024))" "$target_gib"
if (( out_kib > target_kib )); then
    printf '%s\n' 'buck-out remains above target; active or newly-created isolation caches were preserved' >&2
    exit 1
fi
