#!/bin/sh
set -eu
root=${BUCK_DEFAULT_RUNTIME_RESOURCES:-$(pwd -P)}
project=${BUCK_PROJECT_ROOT:-$root}
[ -d "$project" ]
files=$(git -C "$project" ls-files -z -- '*.sh' '*.bzl' 'BUCK' 'README.md' 'docs/*.md' 'docs/*.sh')
[ -n "$files" ]
printf '%s' "$files" | tr '\0' '\n' | while IFS= read -r file; do
    case "$file" in
        *.sh|*.bzl|BUCK|README.md|docs/*.md|docs/*.sh)
            legacy_switch=$(printf '%s%s' -- -scenario)
            if grep -F -- "$legacy_switch" "$project/$file" >/dev/null 2>&1; then
                printf 'removed legacy scenario switch remains in %s\n' "$file" >&2
                exit 1
            fi
            ;;
    esac
done
printf '%s\n' 'scenario removed: passed'
