#!/bin/sh
# Validate the host boundary required by the repository-level relocation check.
# This helper is deliberately side-effect free: it never invokes Buck or the adapter.
set -u

project_root=${1:-}
if [ -z "$project_root" ]; then
    printf '%s\n' 'relocation preflight: missing project root argument' >&2
    exit 1
fi

missing=0
missing_command() {
    printf 'relocation preflight: missing command=%s\n' "$1" >&2
    missing=1
}

lookup_command() {
    command -v "$1" >/dev/null 2>&1
}

buck=${BUCK2:-buck2}
case "$buck" in
    *[!A-Za-z0-9_./:-]*|'')
        printf 'relocation preflight: invalid BUCK2=%s\n' "$buck" >&2
        missing=1
        ;;
    /*)
        if [ ! -f "$buck" ] || [ -L "$buck" ] || [ ! -x "$buck" ]; then
            printf 'relocation preflight: missing BUCK2 executable=%s\n' "$buck" >&2
            missing=1
        fi
        ;;
    *)
        if ! lookup_command "$buck"; then
            printf 'relocation preflight: missing command=%s\n' "$buck" >&2
            missing=1
        fi
        ;;
esac

for command_name in sh env mkdir cp chmod mktemp dirname rm grep sed cat basename tr wc bash realpath awk cut tail ln python3; do
    lookup_command "$command_name" || missing_command "$command_name"
done

if lookup_command sha256sum; then
    :
elif lookup_command shasum; then
    :
else
    printf '%s\n' 'relocation preflight: missing command=sha256sum-or-shasum' >&2
    missing=1
fi

interpreter=${ADAPTER_RELOCATED_PREFLIGHT_TEST_INTERPRETER:-/usr/bin/python3}
if [ ! -f "$interpreter" ] || [ -L "$interpreter" ] || [ ! -x "$interpreter" ]; then
    printf '%s\n' 'relocation preflight: missing interpreter=/usr/bin/python3' >&2
    missing=1
fi

if [ "$missing" -ne 0 ]; then
    exit 1
fi
exit 0
