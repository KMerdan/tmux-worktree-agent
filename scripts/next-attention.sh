#!/usr/bin/env bash

# Quick-jump to next agent waiting for input (prefix+a)
# Finds the first session with status "prompt" and switches to it.
# Skips the current session so repeated presses cycle through waiting agents.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"
source "$SCRIPT_DIR/status-agents.sh"  # for agent_status_icon()

current_session=$(tmux display-message -p '#S' 2>/dev/null)

for session in $(list_sessions); do
    [ "$session" = "$current_session" ] && continue
    tmux has-session -t "$session" 2>/dev/null || continue
    status=$(agent_status_icon "$session")
    if [ "$status" = "prompt" ]; then
        tmux switch-client -t "$session"
        exit 0
    fi
done

tmux display-message -d 2000 "All agents working — no attention needed"
