#!/usr/bin/env bash

set -e

# Get script directory and source utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"

# Main cleanup function
main() {
    local session_name="$1"

    # If no session name provided, use current session
    if [ -z "$session_name" ]; then
        if [ -z "$TMUX" ]; then
            log_error "Not in a tmux session. Please specify session name."
            exit 1
        fi

        session_name=$(get_current_session)
    fi

    # Check if session exists in metadata
    if ! session_in_metadata "$session_name"; then
        log_warn "Session '$session_name' not found in metadata"

        # Check if tmux session exists
        if session_exists "$session_name"; then
            if confirm "Kill tmux session anyway?"; then
                tmux kill-session -t "$session_name"
                log_success "Session killed"
            fi
        else
            log_error "Session not found"
        fi

        exit 0
    fi

    # Get session metadata
    local worktree_path main_repo_path topic branch
    worktree_path=$(get_session_field "$session_name" "worktree_path")
    main_repo_path=$(get_session_field "$session_name" "main_repo_path")
    topic=$(get_session_field "$session_name" "topic")
    branch=$(get_session_field "$session_name" "branch")

    # Show what will be deleted
    echo "╭─ Session to Delete ───────────────────────╮"
    echo "│ Session: $session_name"
    echo "│ Branch:  $branch"
    echo "│ Topic:   $topic"
    echo "│ Path:    $worktree_path"
    echo "╰───────────────────────────────────────────╯"
    echo ""

    # Confirm deletion
    if ! confirm "Kill session and remove worktree?"; then
        log_info "Cancelled"
        exit 0
    fi

    local previous_session=""

    # If we're in the session to be deleted, switch away first
    if [ -n "$TMUX" ]; then
        local current_session
        current_session=$(get_current_session)

        if [ "$current_session" = "$session_name" ]; then
            # Get list of other sessions
            local sessions
            sessions=$(tmux list-sessions -F '#{session_name}' | grep -v "^$session_name$" | head -1)

            if [ -n "$sessions" ]; then
                previous_session="$sessions"
            fi
        fi
    fi

    # Step 1: Kill tmux session
    if session_exists "$session_name"; then
        log_info "Killing tmux session..."
        tmux kill-session -t "$session_name" 2>/dev/null || true
        log_success "Session killed"
    else
        log_warn "Session not running (already killed)"
    fi

    # Step 2: Remove worktree
    if [ -d "$worktree_path" ]; then
        log_info "Removing worktree..."

        # Try git worktree remove first (clean way)
        if [ -d "$main_repo_path" ]; then
            cd "$main_repo_path"

            if git worktree remove "$worktree_path" --force 2>/dev/null; then
                log_success "Worktree removed via git"
            else
                # Fallback to manual deletion
                log_warn "Git worktree remove failed, using rm -rf"
                rm -rf "$worktree_path"
                log_success "Worktree directory deleted"
            fi
        else
            # Main repo gone, just delete directory
            log_warn "Main repo not found, deleting worktree directory"
            rm -rf "$worktree_path"
            log_success "Worktree directory deleted"
        fi
    else
        log_warn "Worktree directory not found (already deleted)"
    fi

    # Step 3: Delete metadata
    log_info "Cleaning metadata..."
    delete_session "$session_name"
    log_success "Metadata cleaned"

    # Step 4: Switch to previous session if needed
    if [ -n "$previous_session" ]; then
        log_info "Switching to session: $previous_session"
        switch_to_session "$previous_session"
    fi

    log_success "Cleanup complete: $session_name"
}

# Run main
main "$@"
