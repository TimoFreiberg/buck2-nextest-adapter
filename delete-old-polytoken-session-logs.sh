#!/bin/sh
set -eu

POLYTOKEN_DIR="$HOME/.local/share/polytoken"
LOG_DIR="$POLYTOKEN_DIR/logs"
SESSION_DIR="$POLYTOKEN_DIR/sessions"

if [ -d "$LOG_DIR" ]; then
    printf 'Deleting regular log files older than 30 days under %s\n' "$LOG_DIR"
    find "$LOG_DIR" -type f -mtime +30 -exec rm -f -- {} +
else
    printf 'Not found: %s\n' "$LOG_DIR"
fi

if [ -d "$SESSION_DIR" ]; then
    printf 'Deleting regular session files older than 30 days under %s\n' "$SESSION_DIR"
    find "$SESSION_DIR" -type f -mtime +30 -exec rm -f -- {} +
else
    printf 'Not found: %s\n' "$SESSION_DIR"
fi
