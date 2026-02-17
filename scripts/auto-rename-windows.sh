#!/usr/bin/env bash
# Auto-rename worktree session windows based on detected processes
# Runs periodically via tmux status bar #() to keep names in sync
# Only touches worktree-managed sessions (from plugin metadata)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PLUGIN_DIR/lib/metadata.sh"

# Known agent/tool names to detect in process tree
KNOWN_AGENTS="claude codex gemini aider opencode vim nvim"

# Detect what agent/tool is running in a pane by checking child processes
detect_pane_agent() {
    local pane_pid="$1"
    local children
    children=$(pgrep -P "$pane_pid" 2>/dev/null) || true
    for cpid in $children; do
        local cmd
        cmd=$(ps -o comm= -p "$cpid" 2>/dev/null) || continue
        for agent in $KNOWN_AGENTS; do
            [[ "$cmd" == "$agent"* ]] && { echo "$agent"; return; }
        done
        # Check grandchildren (agent may be wrapped)
        local grandchildren
        grandchildren=$(pgrep -P "$cpid" 2>/dev/null) || true
        for gpid in $grandchildren; do
            cmd=$(ps -o comm= -p "$gpid" 2>/dev/null) || continue
            for agent in $KNOWN_AGENTS; do
                [[ "$cmd" == "$agent"* ]] && { echo "$agent"; return; }
            done
        done
    done
}

main() {
    local sessions
    sessions=$(list_sessions 2>/dev/null) || return 0
    [ -n "$sessions" ] || return 0

    while IFS= read -r session_name; do
        [ -n "$session_name" ] || continue
        tmux has-session -t "$session_name" 2>/dev/null || continue

        local topic
        topic=$(get_session_field "$session_name" "topic" 2>/dev/null) || continue
        [ -n "$topic" ] || continue

        while IFS='|' read -r window_id window_index; do
            [ -n "$window_id" ] || continue

            # Collect unique agents from all panes in this window
            local agents=()
            while IFS='|' read -r pane_pid pane_cmd; do
                local detected
                detected=$(detect_pane_agent "$pane_pid")
                if [ -z "$detected" ]; then
                    # Fallback: check pane_current_command for known tools
                    for agent in $KNOWN_AGENTS; do
                        [[ "$pane_cmd" == "$agent"* ]] && { detected="$agent"; break; }
                    done
                fi
                if [ -n "$detected" ]; then
                    # Deduplicate
                    local dup=false
                    for a in "${agents[@]+"${agents[@]}"}"; do
                        [ "$a" = "$detected" ] && dup=true
                    done
                    $dup || agents+=("$detected")
                fi
            done < <(tmux list-panes -t "$window_id" -F '#{pane_pid}|#{pane_current_command}')

            # Build window name
            local agent_part
            if [ ${#agents[@]} -eq 0 ]; then
                agent_part="sh"
            else
                agent_part=$(IFS='+'; echo "${agents[*]}")
            fi
            local new_name="${agent_part}:${topic}"

            # Only rename if different (avoid flicker)
            local current_name
            current_name=$(tmux display-message -t "$window_id" -p '#{window_name}' 2>/dev/null) || continue
            if [ "$current_name" != "$new_name" ]; then
                tmux rename-window -t "$window_id" "$new_name"
            fi
        done < <(tmux list-windows -t "$session_name" -F '#{window_id}|#{window_index}')
    done <<< "$sessions"
}

main
