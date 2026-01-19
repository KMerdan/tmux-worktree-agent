#!/usr/bin/env bash

# Session description management for tmux-worktree-agent
# Provides get, set, and prompt commands for session descriptions

set -e

# Get script directory and source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"

# Get current session name
get_current_session() {
    # Try tmux first
    if [ -n "${TMUX:-}" ]; then
        tmux display-message -p '#S'
        return 0
    fi

    # Fall back to worktree path detection
    local current_path
    current_path=$(pwd)

    find_session_by_path "$current_path"
}

# Get description for a session
cmd_get() {
    local session_name="${1:-}"

    if [ -z "$session_name" ]; then
        session_name=$(get_current_session)
    fi

    if [ -z "$session_name" ]; then
        log_error "Could not determine session name"
        return 1
    fi

    if ! session_in_metadata "$session_name"; then
        return 1
    fi

    get_session_description "$session_name"
}

# Set description for a session
cmd_set() {
    local session_name="$1"
    local description="$2"

    if [ -z "$session_name" ]; then
        log_error "Usage: $0 set <session-name> <description>"
        return 1
    fi

    # If only one argument, treat it as description for current session
    if [ -z "$description" ]; then
        description="$session_name"
        session_name=$(get_current_session)

        if [ -z "$session_name" ]; then
            log_error "Could not determine session name"
            return 1
        fi
    fi

    if ! session_in_metadata "$session_name"; then
        log_error "Session '$session_name' not found in metadata"
        return 1
    fi

    update_session_description "$session_name" "$description"
    log_success "Description updated for session '$session_name'"
}

# Prompt for description
cmd_prompt() {
    local session_name="${1:-}"

    if [ -z "$session_name" ]; then
        session_name=$(get_current_session)
    fi

    if [ -z "$session_name" ]; then
        log_error "Could not determine session name"
        return 1
    fi

    if ! session_in_metadata "$session_name"; then
        log_error "Session '$session_name' not found in metadata"
        return 1
    fi

    # Get current description if any
    local current_desc
    current_desc=$(get_session_description "$session_name" || echo "")

    if [ -n "$current_desc" ]; then
        echo "Current description: $current_desc"
        echo ""
    fi

    # Prompt for new description
    local description
    description=$(prompt "What is this session about? (Description for AI agents)")

    if [ -z "$description" ]; then
        log_info "No description provided"
        return 0
    fi

    update_session_description "$session_name" "$description"
    log_success "Description saved"
}

# Show usage
usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  get [session-name]              Get description for session (uses current if not specified)
  set <description>               Set description for current session
  set <session-name> <description> Set description for specific session
  prompt [session-name]           Interactively prompt for description

Examples:
  $(basename "$0") get
  $(basename "$0") set "Implementing OAuth2 authentication"
  $(basename "$0") set my-session "Bug fix for login flow"
  $(basename "$0") prompt

EOF
}

# Main
main() {
    local command="${1:-}"

    if [ -z "$command" ]; then
        usage
        exit 1
    fi

    case "$command" in
        get)
            shift
            cmd_get "$@"
            ;;
        set)
            shift
            cmd_set "$@"
            ;;
        prompt)
            shift
            cmd_prompt "$@"
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown command: $command"
            echo ""
            usage
            exit 1
            ;;
    esac
}

main "$@"
