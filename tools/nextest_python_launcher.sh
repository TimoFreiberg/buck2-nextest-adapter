#!/bin/sh
set -eu

if [ -n "${ADAPTER_RELOCATED_RECORD_DIR:-}" ]; then
    if [ ! -f "$ADAPTER_RELOCATED_RECORD_HELPER" ]; then
        ADAPTER_RELOCATED_RECORD_HELPER=${BUCK_PROJECT_ROOT:-.}/tools/nextest_relocated_records.py
    fi
    phase=setup
    case " $* " in
        *' cargo nextest '*) phase=nextest ;;
    esac
    /usr/bin/python3 "$ADAPTER_RELOCATED_RECORD_HELPER" write-launcher "$0" "$phase"
fi
exec /usr/bin/python3 "$@"
