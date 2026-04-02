#!/usr/bin/env bash

# Compact agent status for tmux status bar
# Color-coded, truncated, easy to scan at a glance
#
# States:
#   ● active  (green)  - agent is running/thinking/streaming
#   ⏎ prompt  (orange) - agent waiting for user input - needs attention!
#   ◌ off     (grey)   - no agent process running
#   ✗ dead    (red)    - session gone

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"

MAX_TOPIC_LEN=14

truncate() {
    local str="$1" max="$2"
    if [ ${#str} -gt "$max" ]; then
        echo "${str:0:$((max-1))}…"
    else
        echo "$str"
    fi
}

# Check if pane content shows an agent waiting for user input
# Returns 0 (true) if agent is at a prompt, 1 otherwise
is_waiting_for_input() {
    local pane_id="$1"
    local last_lines
    last_lines=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null | tail -15)
    [ -z "$last_lines" ] && return 1

    # Codex: always shows "› " and "? for shortcuts" as permanent UI frame
    # When RUNNING: shows "esc to interrupt" above the frame
    # When WAITING: no such line — just the prompt frame
    if echo "$last_lines" | grep -q "? for shortcuts"; then
        echo "$last_lines" | grep -q "esc to interrupt" && return 1  # running
        return 0  # waiting
    fi

    # Claude: detect by permanent UI frame (❯ prompt + model name in status)
    # Instead of matching volatile UI text, use pane activity timing:
    #   - "Esc to cancel" → permission prompt (always reliable)
    #   - Recent pane output (< 8s) → agent is running (streaming/tools)
    #   - No recent output → idle at prompt
    if echo "$last_lines" | grep -qE "^❯|Opus|Sonnet|Haiku"; then
        # Permission prompt — always needs user
        echo "$last_lines" | grep -q "Esc to cancel" && return 0
        # Use pane activity timing — running agents produce constant output
        local pane_activity current_time
        pane_activity=$(tmux display-message -t "$pane_id" -p "#{pane_activity}" 2>/dev/null)
        current_time=$(date +%s)
        if [ -n "$pane_activity" ] && [ $((current_time - pane_activity)) -lt 8 ]; then
            return 1  # recent output — running
        fi
        return 0  # no recent output — idle at prompt
    fi

    return 1
}

# Determine agent status for a session
# Returns: active | prompt | off | dead
agent_status_icon() {
    local session_name="$1"

    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        echo "dead"
        return
    fi

    local agent_cmd
    agent_cmd=$(get_session_agent "$session_name")
    if [ -z "$agent_cmd" ]; then
        echo "off"
        return
    fi

    local agent_process="${agent_cmd%% *}"

    # Check all panes in the session for agent processes
    local found_agent=false
    local found_prompt=false
    local found_active=false

    while IFS='|' read -r pane_id pane_pid; do
        [ -n "$pane_pid" ] || continue

        # Look for agent process in children
        local agent_pid
        agent_pid=$(find_agent_pid "$pane_pid" "$agent_process")

        if [ -z "$agent_pid" ]; then
            # Also check for any known agent in children
            for known in claude codex gemini aider opencode; do
                agent_pid=$(find_agent_pid "$pane_pid" "$known")
                [ -n "$agent_pid" ] && break
            done
        fi

        [ -z "$agent_pid" ] && continue
        found_agent=true

        # Check if this pane shows a prompt (waiting for input)
        if is_waiting_for_input "$pane_id"; then
            found_prompt=true
        else
            # Agent exists but not at prompt → actively working
            local cpu_usage
            cpu_usage=$(ps -p "$agent_pid" -o %cpu= 2>/dev/null | awk '{print int($1)}')
            if [ -n "$cpu_usage" ] && [ "$cpu_usage" -ge 2 ]; then
                found_active=true
            else
                # Low CPU but not at prompt — could be streaming or between operations
                local last_activity current_time time_diff
                last_activity=$(tmux display-message -t "$pane_id" -p "#{pane_activity}" 2>/dev/null)
                current_time=$(date +%s)
                time_diff=$((current_time - last_activity))
                if [ "$time_diff" -lt 10 ]; then
                    found_active=true
                fi
            fi
        fi
    done < <(tmux list-panes -t "$session_name" -F '#{pane_id}|#{pane_pid}')

    if ! $found_agent; then
        echo "off"
    elif $found_active; then
        echo "active"
    elif $found_prompt; then
        echo "prompt"
    else
        # Agent running but can't determine state — assume active
        echo "active"
    fi
}

main() {
    if [ ! -f "$METADATA_FILE" ]; then
        exit 0
    fi

    local sessions
    sessions=$(list_sessions)
    [ -z "$sessions" ] && exit 0

    local prompt_count=0 active_count=0 off_count=0 dead_count=0

    for session in $sessions; do
        tmux has-session -t "$session" 2>/dev/null || continue
        local status
        status=$(agent_status_icon "$session")
        case "$status" in
            prompt) ((prompt_count++)) ;;
            active) ((active_count++)) ;;
            off)    ((off_count++)) ;;
            dead)   ((dead_count++)) ;;
        esac
    done

    local total=$((prompt_count + active_count + off_count + dead_count))
    [ $total -eq 0 ] && exit 0

    local output=""
    [ $prompt_count -gt 0 ] && output+="#[fg=#fab387]⏎${prompt_count} "
    [ $dead_count -gt 0 ]   && output+="#[fg=#f38ba8]✗${dead_count} "
    [ $active_count -gt 0 ] && output+="#[fg=#a6e3a1]●${active_count} "
    [ $off_count -gt 0 ]    && output+="#[fg=#6c7086]◌${off_count}"

    echo "#[fg=#585b70]▏${output}#[fg=#585b70]▕"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
