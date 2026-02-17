#!/usr/bin/env bash
# Returns repo name for status line, falls back to session name
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo=$("$SCRIPT_DIR/session-info.sh" "" repo 2>/dev/null)
if [ -z "$repo" ] || [ "$repo" = "Regular session" ]; then
    tmux display-message -p '#S'
else
    echo "$repo"
fi
