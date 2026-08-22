#!/bin/sh
set -eu

LOG_DIR="$HOME/.local/share/polytoken/logs"

if [ -d "$LOG_DIR" ]; then
    printf 'Deleting regular log files older than 30 days under %s\n' "$LOG_DIR"
    find "$LOG_DIR" -type f -mtime +30 -exec rm -f -- {} +
else
    printf 'Not found: %s\n' "$LOG_DIR"
fi
