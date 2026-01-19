#!/usr/bin/env bash

# Shell initialization for tmux-worktree-agent sessions
# Source this file in your ~/.bashrc or ~/.zshrc to enable session banners and description prompts

# Detect plugin directory
_WORKTREE_PLUGIN_DIR="${WORKTREE_PLUGIN_DIR:-$HOME/.tmux/plugins/tmux-worktree-agent}"

# Initialize worktree session
worktree_agent_init() {
    # Only run in tmux sessions
    if [ -z "${TMUX:-}" ]; then
        return 0
    fi

    # Get current session name
    local session_name
    session_name=$(tmux display-message -p '#S' 2>/dev/null) || return 0

    # Source dependencies
    if [ ! -f "$_WORKTREE_PLUGIN_DIR/lib/metadata.sh" ]; then
        return 0
    fi

    source "$_WORKTREE_PLUGIN_DIR/lib/metadata.sh"

    # Check if this session is in metadata (plugin-managed)
    if ! session_in_metadata "$session_name" 2>/dev/null; then
        return 0
    fi

    # Get session metadata
    local repo branch topic worktree_path description
    repo=$(get_session_field "$session_name" "repo")
    branch=$(get_session_field "$session_name" "branch")
    topic=$(get_session_field "$session_name" "topic")
    worktree_path=$(get_session_field "$session_name" "worktree_path")
    description=$(get_session_description "$session_name" 2>/dev/null || echo "")

    # Prompt for description if not set
    if [ -z "$description" ]; then
        echo ""
        echo "This session doesn't have a description yet."

        # Read from /dev/tty for popup compatibility
        printf "What is this session about? (Description for AI agents): " >&2
        read -r description < /dev/tty

        if [ -n "$description" ]; then
            update_session_description "$session_name" "$description"
        fi
    fi

    # Display banner
    local term_width
    term_width=$(tput cols 2>/dev/null || echo 80)
    local banner_width=$((term_width > 60 ? 60 : term_width))

    echo ""
    printf "╭─ Worktree Session "
    printf '─%.0s' $(seq 1 $((banner_width - 21)))
    printf "╮\n"

    printf "│ %-${banner_width}s │\n" "Repo:   $repo"
    printf "│ %-${banner_width}s │\n" "Branch: $branch"
    printf "│ %-${banner_width}s │\n" "Topic:  $topic"

    if [ -n "$description" ]; then
        printf "│ %-${banner_width}s │\n" ""

        # Word wrap description
        local max_width=$((banner_width - 4))
        echo "$description" | fold -s -w "$max_width" | while IFS= read -r line; do
            printf "│ 📝 %-$((banner_width - 4))s │\n" "$line"
        done
    fi

    printf "╰"
    printf '─%.0s' $(seq 1 $((banner_width - 2)))
    printf "╯\n"
    echo ""
}

# Auto-run on shell startup (only once per shell)
if [ -z "${_WORKTREE_AGENT_INIT_DONE:-}" ]; then
    export _WORKTREE_AGENT_INIT_DONE=1
    worktree_agent_init
fi
