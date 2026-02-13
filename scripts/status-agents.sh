#!/usr/bin/env bash

# Compact agent status for tmux status bar
# Color-coded, truncated, easy to scan at a glance

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

# Returns: icon color_code
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
    local pane_pid
    pane_pid=$(tmux list-panes -t "$session_name" -F "#{pane_pid}" 2>/dev/null | head -1)

    if [ -z "$pane_pid" ]; then
        echo "off"
        return
    fi

    local agent_pid
    agent_pid=$(find_agent_pid "$pane_pid" "$agent_process")

    if [ -z "$agent_pid" ]; then
        echo "off"
        return
    fi

    local last_activity current_time time_diff
    last_activity=$(tmux display-message -t "$session_name" -p "#{pane_activity}" 2>/dev/null)
    current_time=$(date +%s)
    time_diff=$((current_time - last_activity))

    local cpu_usage
    cpu_usage=$(ps -p "$agent_pid" -o %cpu= 2>/dev/null | awk '{print int($1)}')

    if [ -z "$cpu_usage" ]; then
        echo "idle"
        return
    fi

    if [ "$time_diff" -lt 15 ] && [ "$cpu_usage" -ge 5 ]; then
        echo "active"
    else
        echo "idle"
    fi
}

main() {
    if [ ! -f "$METADATA_FILE" ]; then
        exit 0
    fi

    local sessions
    sessions=$(list_sessions)

    if [ -z "$sessions" ]; then
        exit 0
    fi

    local current_session=""
    if [ -n "$TMUX" ]; then
        current_session=$(get_current_session)
    fi

    local output=""
    local count=0

    for session in $sessions; do
        if ! tmux has-session -t "$session" 2>/dev/null; then
            continue
        fi

        local agent_cmd topic status
        agent_cmd=$(get_session_agent "$session")
        topic=$(get_session_field "$session" "topic")
        status=$(agent_status_icon "$session")

        local agent_label="${agent_cmd:-sh}"
        local short_topic
        short_topic=$(truncate "$topic" "$MAX_TOPIC_LEN")

        # Color per status
        #   active = green ●    idle = yellow ○    off = dim ◌    dead = red ✗
        local icon color reset="#[default]"
        case "$status" in
            active) icon="●" color="#[fg=#a6e3a1]" ;;   # green
            idle)   icon="○" color="#[fg=#f9e2af]" ;;   # yellow
            off)    icon="◌" color="#[fg=#6c7086]" ;;   # grey
            dead)   icon="✗" color="#[fg=#f38ba8]" ;;   # red
        esac

        # Highlight current session
        local label_style="#[fg=#cdd6f4]"
        if [ "$session" = "$current_session" ]; then
            label_style="#[fg=#cdd6f4,bold,underscore]"
        fi

        # Separator between entries
        if [ $count -gt 0 ]; then
            output+=" #[fg=#585b70]│ "
        fi

        output+="${color}${icon} ${label_style}${agent_label}#[nobold,nounderscore]#[fg=#9399b2]:${short_topic}${reset}"
        ((count++))
    done

    if [ $count -eq 0 ]; then
        exit 0
    fi

    echo "#[fg=#585b70]▏${output} #[fg=#585b70]▕"
}

main
