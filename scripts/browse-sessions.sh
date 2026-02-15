#!/usr/bin/env bash

set -e

# Get script directory and source utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"

# Check dependencies
if ! check_dependencies; then
    exit 1
fi

# Generate preview for fzf
generate_preview() {
    local session_name="$1"

    if [ -z "$session_name" ]; then
        return
    fi

    local session_data
    session_data=$(get_session "$session_name")

    if [ "$session_data" = "{}" ]; then
        echo "No metadata found"
        return
    fi

    # Extract fields
    local repo branch worktree_path created_at description agent_cmd
    repo=$(echo "$session_data" | jq -r '.repo')
    branch=$(echo "$session_data" | jq -r '.branch')
    worktree_path=$(echo "$session_data" | jq -r '.worktree_path')
    created_at=$(echo "$session_data" | jq -r '.created_at')
    description=$(echo "$session_data" | jq -r '.description // empty')
    agent_cmd=$(echo "$session_data" | jq -r '.agent_cmd // empty')

    # Display session info
    echo "╭─ Session Info ────────────────────────────╮"
    echo "│ Session: $session_name"
    echo "│ Repo:    $repo"
    echo "│ Branch:  $branch"
    if [ -n "$agent_cmd" ]; then
        echo "│ Agent:   $agent_cmd"
    fi
    echo "│ Created: $created_at"

    if [ -n "$description" ]; then
        # Truncate description if too long (max 100 chars)
        local desc_display="$description"
        if [ ${#description} -gt 100 ]; then
            desc_display="${description:0:97}..."
        fi
        echo "│"
        echo "│ Description:"
        echo "│   $desc_display"
    fi

    echo "╰───────────────────────────────────────────╯"
    echo ""

    # Check session status
    if tmux has-session -t "$session_name" 2>/dev/null; then
        echo "✓ Session active"

        # Show windows
        echo ""
        echo "Windows:"
        tmux list-windows -t "$session_name" -F "  #I: #W"
    else
        echo "⚠ Session not running"
    fi

    echo ""

    # Check worktree status
    if [ -d "$worktree_path" ]; then
        echo "✓ Worktree exists: $worktree_path"

        # Show git status if directory exists
        if cd "$worktree_path" 2>/dev/null; then
            echo ""
            echo "Git Status:"
            git status --short 2>/dev/null | head -10 | sed 's/^/  /'

            if [ "$(git status --short 2>/dev/null | wc -l)" -gt 10 ]; then
                echo "  ..."
            fi
        fi
    else
        echo "⚠ Worktree deleted"
    fi
}

# Get agent status for a session
get_agent_status() {
    local session_name="$1"

    # If session doesn't exist, return N/A
    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        echo "─"
        return
    fi

    # Get agent command from session metadata, fallback to env
    local agent_cmd
    agent_cmd=$(get_session_agent "$session_name")
    if [ -z "$agent_cmd" ]; then
        agent_cmd="${WORKTREE_AGENT_CMD:-claude}"
    fi
    local agent_process="${agent_cmd%% *}"  # First word only

    # Find agent process in session's process tree
    local pane_pid=$(tmux list-panes -t "$session_name" -F "#{pane_pid}" | head -1)

    if [ -z "$pane_pid" ]; then
        echo "◌"  # No pane found
        return
    fi

    local agent_pid=$(find_agent_pid "$pane_pid" "$agent_process")

    if [ -z "$agent_pid" ]; then
        echo "◌"  # No agent process
        return
    fi

    # Check activity: output in last 15 seconds
    local last_activity=$(tmux display-message -t "$session_name" -p "#{pane_activity}")
    local current_time=$(date +%s)
    local time_diff=$((current_time - last_activity))

    # Check CPU usage
    local cpu_usage=$(ps -p "$agent_pid" -o %cpu= 2>/dev/null | awk '{print int($1)}')

    # Validate cpu_usage before arithmetic comparison
    if [ -z "$cpu_usage" ]; then
        echo "○"  # Can't determine CPU, assume idle
        return
    fi

    if [ "$time_diff" -lt 15 ] && [ "$cpu_usage" -ge 5 ]; then
        echo "●"  # Working
    else
        echo "○"  # Waiting/idle
    fi
}

# Export function for fzf preview
export -f generate_preview
export SCRIPT_DIR PLUGIN_DIR

# Build session list
build_session_list() {
    local sessions
    sessions=$(list_sessions)

    if [ -z "$sessions" ]; then
        echo "No sessions found"
        return 1
    fi

    local output=""

    for session in $sessions; do
        local session_data
        session_data=$(get_session "$session")

        local repo branch worktree_path status_icon

        repo=$(echo "$session_data" | jq -r '.repo')
        branch=$(echo "$session_data" | jq -r '.branch')
        worktree_path=$(echo "$session_data" | jq -r '.worktree_path')

        # Determine status
        local session_exists=false
        local worktree_exists=false

        if tmux has-session -t "$session" 2>/dev/null; then
            session_exists=true
        fi

        if [ -d "$worktree_path" ]; then
            worktree_exists=true
        fi

        # Set status icon and color
        if $session_exists && $worktree_exists; then
            status_icon="●"  # Active
        elif ! $session_exists && $worktree_exists; then
            status_icon="○"  # Worktree only (no session)
        elif $session_exists && ! $worktree_exists; then
            status_icon="⚠"  # Session only (worktree deleted)
        else
            status_icon="✗"  # Both missing (stale)
        fi

        # Get agent status
        local agent_status="─"
        if $session_exists; then
            agent_status=$(get_agent_status "$session")
        fi

        # Get agent name from metadata
        local agent_name
        agent_name=$(echo "$session_data" | jq -r '.agent_cmd // empty')
        if [ -z "$agent_name" ]; then
            agent_name="─"
        fi

        # Format: session_status agent_status session agent branch path
        printf "%-2s %-2s %-35s %-10s %-25s %s\n" \
            "$status_icon" \
            "$agent_status" \
            "$session" \
            "$agent_name" \
            "$branch" \
            "$worktree_path"
    done
}

# Main browser
main() {
    # Auto-cleanup stale metadata
    local cleaned
    cleaned=$(clean_orphaned_metadata)

    if [ "$cleaned" -gt 0 ]; then
        log_info "Cleaned $cleaned stale metadata entries"
    fi

    # Build session list
    local session_list
    session_list=$(build_session_list)

    if [ $? -ne 0 ]; then
        log_warn "No worktree sessions found"
        log_info "Create one with: prefix + C-w"
        echo ""
        read -n 1 -s -r -p "Press any key to close..." < /dev/tty
        exit 0
    fi

    # fzf interface
    local selected
    selected=$(echo "$session_list" | fzf \
        --ansi \
        --header="Worktree Sessions ($(count_sessions) active) | [S][A] Session Agent Branch | Enter: switch | Ctrl-d: delete | Tab: preview" \
        --header-lines=0 \
        --layout=reverse \
        --preview="bash -c 'source $SCRIPT_DIR/utils.sh && source $PLUGIN_DIR/lib/metadata.sh && generate_preview {3}'" \
        --preview-window=right:60%:wrap \
        --bind='ctrl-d:execute(bash -c "source $SCRIPT_DIR/utils.sh && source $PLUGIN_DIR/lib/metadata.sh && bash $SCRIPT_DIR/kill-worktree.sh {3}")' \
        --bind='ctrl-r:reload(bash -c "source $SCRIPT_DIR/utils.sh && source $PLUGIN_DIR/lib/metadata.sh && '"$(declare -f get_agent_status; declare -f build_session_list)"' && build_session_list")' \
        --bind='tab:toggle-preview' \
        --bind='esc:cancel')

    if [ -z "$selected" ]; then
        exit 0
    fi

    # Extract session name (third field)
    local session_name
    session_name=$(echo "$selected" | awk '{print $3}')

    # Get status icon
    local status_icon
    status_icon=$(echo "$selected" | awk '{print $1}')

    # Handle based on status
    case "$status_icon" in
        ●)
            # Active session - switch to it
            switch_to_session "$session_name"
            ;;
        ○)
            # Worktree exists, no session - offer to create
            if confirm "Create session for existing worktree?"; then
                local worktree_path
                worktree_path=$(get_session_field "$session_name" "worktree_path")
                local stored_agent
                stored_agent=$(get_session_agent "$session_name")
                local topic
                topic=$(get_session_field "$session_name" "topic")

                # Create session with stored agent
                if [ -n "$stored_agent" ]; then
                    create_tmux_session "$session_name" "$worktree_path" true "$stored_agent" "$topic"
                else
                    create_tmux_session "$session_name" "$worktree_path" false "" "$topic"
                fi

                log_success "Session created: $session_name"
                switch_to_session "$session_name"
            fi
            ;;
        ⚠)
            # Session exists, worktree deleted - offer options
            local action
            action=$(choose "Worktree missing. What would you like to do?" \
                "Recreate worktree" "Kill session" "Cancel")

            case "$action" in
                "Recreate worktree")
                    local worktree_path
                    worktree_path=$(get_session_field "$session_name" "worktree_path")
                    local branch
                    branch=$(get_session_field "$session_name" "branch")
                    local main_repo_path
                    main_repo_path=$(get_session_field "$session_name" "main_repo_path")

                    # Recreate worktree
                    cd "$main_repo_path"
                    mkdir -p "$(dirname "$worktree_path")"
                    git worktree add "$worktree_path" "$branch"

                    log_success "Worktree recreated"
                    switch_to_session "$session_name"
                    ;;
                "Kill session")
                    bash "$SCRIPT_DIR/kill-worktree.sh" "$session_name"
                    ;;
                Cancel|*)
                    exit 0
                    ;;
            esac
            ;;
        ✗)
            # Stale metadata - should have been cleaned
            log_warn "Stale entry: $session_name"
            delete_session "$session_name"
            ;;
    esac
}

# Run main directly (popup handled by keybinding)
main
