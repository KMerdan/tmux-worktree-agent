#!/usr/bin/env bash

# Reconcile worktree sessions - detect and fix orphaned states

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

# Main reconciliation
main() {
    log_info "Reconciling worktree sessions..."
    echo ""

    local ok_count=0
    local orphaned_session_count=0
    local orphaned_worktree_count=0
    local stale_count=0

    # Arrays to track issues
    local orphaned_sessions=()
    local orphaned_worktrees=()

    # Step 1: Check each metadata entry
    local sessions
    sessions=$(list_sessions)

    for session in $sessions; do
        local worktree_path
        worktree_path=$(get_session_field "$session" "worktree_path")

        local session_exists=false
        local worktree_exists=false

        if tmux has-session -t "$session" 2>/dev/null; then
            session_exists=true
        fi

        if [ -d "$worktree_path" ]; then
            worktree_exists=true
        fi

        # Categorize
        if $session_exists && $worktree_exists; then
            ((ok_count++))
        elif $session_exists && ! $worktree_exists; then
            ((orphaned_session_count++))
            orphaned_sessions+=("$session")
        elif ! $session_exists && $worktree_exists; then
            ((orphaned_worktree_count++))
            orphaned_worktrees+=("$session")
        else
            # Both missing - stale metadata
            ((stale_count++))
            delete_session "$session"
        fi
    done

    # Step 2: Scan for untracked worktrees
    # (worktrees that exist in git but not in our metadata)
    local worktree_base
    worktree_base=$(expand_tilde "${WORKTREE_PATH:-$HOME/.worktrees}")

    if [ -d "$worktree_base" ]; then
        # Find all git directories in worktree base
        find "$worktree_base" -type d -name ".git" 2>/dev/null | while read -r git_dir; do
            local wt_path
            wt_path=$(dirname "$git_dir")

            # Check if we have metadata for this path
            local found_session
            found_session=$(find_session_by_path "$wt_path")

            if [ -z "$found_session" ]; then
                log_warn "Found untracked worktree: $wt_path"
            fi
        done
    fi

    # Display summary
    echo ""
    echo "╭─ Reconciliation Summary ──────────────────╮"
    echo "│"

    if [ $ok_count -gt 0 ]; then
        echo "│ ✓ $ok_count sessions OK"
    fi

    if [ $orphaned_session_count -gt 0 ]; then
        echo "│ ⚠ $orphaned_session_count orphaned (worktree deleted)"
    fi

    if [ $orphaned_worktree_count -gt 0 ]; then
        echo "│ ⚠ $orphaned_worktree_count orphaned (no session)"
    fi

    if [ $stale_count -gt 0 ]; then
        echo "│ ✗ $stale_count stale metadata cleaned"
    fi

    echo "│"
    echo "╰───────────────────────────────────────────╯"
    echo ""

    # Show details of orphaned sessions
    if [ ${#orphaned_sessions[@]} -gt 0 ]; then
        echo "Orphaned Sessions (worktree deleted):"
        for session in "${orphaned_sessions[@]}"; do
            local branch
            branch=$(get_session_field "$session" "branch")
            echo "  ⚠ $session ($branch)"
        done
        echo ""
        log_info "Use browser (prefix + w) to recreate or clean up"
        echo ""
    fi

    # Show details of orphaned worktrees
    if [ ${#orphaned_worktrees[@]} -gt 0 ]; then
        echo "Orphaned Worktrees (no session):"
        for session in "${orphaned_worktrees[@]}"; do
            local branch worktree_path
            branch=$(get_session_field "$session" "branch")
            worktree_path=$(get_session_field "$session" "worktree_path")
            echo "  ○ $session ($branch) - $worktree_path"
        done
        echo ""
        log_info "Use browser (prefix + w) to create sessions"
        echo ""
    fi

    # Summary message
    if [ $orphaned_session_count -eq 0 ] && [ $orphaned_worktree_count -eq 0 ] && [ $stale_count -eq 0 ]; then
        log_success "All sessions are in sync!"
    else
        log_info "Open browser (prefix + w) to manage orphaned sessions"
    fi

    # Pause so user can see the message
    echo ""
    read -n 1 -s -r -p "Press any key to close..."
}

# Run main in tmux popup if available
if [ -n "$TMUX" ]; then
    display_in_tmux "bash $0"
else
    main
fi
