#!/usr/bin/env bash

# Get current session metadata for status line integration

set -e

# Get script directory and source utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"

# Main function
main() {
    local session_name="$1"
    local format="${2:-full}"

    # If no session provided, use current
    if [ -z "$session_name" ]; then
        if [ -z "$TMUX" ]; then
            echo "Not in tmux"
            exit 1
        fi

        session_name=$(get_current_session)
    fi

    # Check if session is in metadata
    if ! session_in_metadata "$session_name"; then
        # Not a worktree session
        if [ "$format" = "icon" ]; then
            echo ""
        else
            echo "Regular session"
        fi
        exit 0
    fi

    # Get metadata
    local repo branch topic worktree_path description
    repo=$(get_session_field "$session_name" "repo")
    branch=$(get_session_field "$session_name" "branch")
    topic=$(get_session_field "$session_name" "topic")
    worktree_path=$(get_session_field "$session_name" "worktree_path")
    description=$(get_session_description "$session_name" 2>/dev/null || echo "")

    # Output based on format
    case "$format" in
        icon)
            echo "🌳"
            ;;
        branch)
            echo "$branch"
            ;;
        topic)
            echo "$topic"
            ;;
        repo)
            echo "$repo"
            ;;
        path)
            echo "$worktree_path"
            ;;
        description)
            echo "$description"
            ;;
        short)
            echo "🌳 $branch"
            ;;
        full)
            echo "🌳 $repo/$topic ($branch)"
            ;;
        status-line)
            # Format for tmux status line
            echo "[$session_name] 🌳 $branch"
            ;;
        json)
            get_session "$session_name"
            ;;
        *)
            echo "Unknown format: $format"
            exit 1
            ;;
    esac
}

# Run main
main "$@"
