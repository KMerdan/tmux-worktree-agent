#!/usr/bin/env bash

# Get script directory and source utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"

# Brief pause on error so user can read messages before popup closes
trap 'rc=$?; if [ $rc -ne 0 ]; then sleep 1.5; fi; exit $rc' EXIT

# Parse arguments
QUICK_MODE=false
if [ "$1" = "--quick" ]; then
    QUICK_MODE=true
fi

# Check dependencies
if ! check_dependencies; then
    exit 1
fi

# Main workflow
main() {
    local repo_path branch_name topic session_name worktree_path
    local is_new_branch=false

    # Step 1: Detect git repository
    if ! is_git_repo; then
        log_warn "Not in a git repository"

        if confirm "Initialize git here?"; then
            git init
            log_success "Git repository initialized"
            repo_path=$(pwd)
        else
            log_error "Please run this from a git repository"
            exit 1
        fi
    else
        repo_path=$(get_repo_root)
    fi

    local repo_name
    repo_name=$(get_repo_name "$repo_path")

    # Step 2: Get branch and topic
    if [ "$QUICK_MODE" = true ]; then
        # Quick mode: topic only, auto-generate branch from current HEAD
        local current_branch
        current_branch=$(get_current_branch)

        if [ -z "$current_branch" ] || [ "$current_branch" = "HEAD" ]; then
            log_error "Not on a valid branch. Use full create mode (prefix + C-w)"
            exit 1
        fi

        # Prompt for topic only
        topic=$(prompt "Topic (branch wt/<topic> from $current_branch)")

        if [ -z "$topic" ]; then
            log_error "Topic required"
            exit 1
        fi

        topic=$(sanitize_name "$topic")
        branch_name="wt/$topic"
        is_new_branch=true
        log_info "Creating worktree: branch $branch_name from $current_branch"
    else
        # Full mode: interactive branch selection with arrow navigation
        echo "=== Create Worktree Session ==="
        echo ""

        log_info "Select branch (or type new branch name)..."
        branch_name=$(select_branch "$repo_path")

        # Check if user cancelled (select_branch returns non-zero)
        if [ $? -ne 0 ] || [ -z "$branch_name" ]; then
            log_error "No branch selected"
            exit 1
        fi

        log_info "Branch name entered: $branch_name"

        # Check if branch exists
        cd "$repo_path" || exit 1
        if ! git rev-parse --verify "$branch_name" >/dev/null 2>&1; then
            if confirm "Branch '$branch_name' doesn't exist. Create new branch?"; then
                is_new_branch=true
            else
                log_info "Cancelled"
                exit 0
            fi
        fi

        # Get topic/description
        topic=$(prompt "Topic/description")

        if [ -z "$topic" ]; then
            log_error "Topic required"
            exit 1
        fi

        topic=$(sanitize_name "$topic")
    fi

    log_info "Topic: $topic"

    # Step 4: Generate session name
    session_name=$(generate_session_name "$repo_name" "$topic")

    # Check for duplicate session
    if session_exists "$session_name"; then
        log_warn "Session '$session_name' already exists"

        local action
        action=$(choose "What would you like to do?" "Attach" "Rename" "Cancel")

        case "$action" in
            Attach)
                log_info "Attaching to existing session..."
                switch_to_session "$session_name"
                exit 0
                ;;
            Rename)
                topic=$(prompt "New topic name")
                topic=$(sanitize_name "$topic")
                session_name=$(generate_session_name "$repo_name" "$topic")

                if session_exists "$session_name"; then
                    log_error "Session '$session_name' still exists. Aborting."
                    exit 1
                fi
                ;;
            Cancel|*)
                log_info "Cancelled"
                exit 0
                ;;
        esac
    fi

    # Step 5: Create worktree
    worktree_path=$(get_worktree_path "$repo_name" "$topic")

    # Check if worktree directory already exists
    if [ -d "$worktree_path" ]; then
        log_warn "Worktree directory already exists: $worktree_path"

        # Check if it's a valid git worktree
        if cd "$worktree_path" && git rev-parse --git-dir >/dev/null 2>&1; then
            log_info "Valid worktree found. Creating session for it..."

            # Create session and metadata
            create_session_and_metadata "$session_name" "$repo_name" "$topic" \
                "$branch_name" "$worktree_path" "$repo_path"
            exit 0
        else
            log_error "Directory exists but is not a git worktree"
            exit 1
        fi
    fi

    # Create parent directory
    mkdir -p "$(dirname "$worktree_path")"

    log_info "Creating worktree at: $worktree_path"

    # Create worktree
    cd "$repo_path"

    if [ "$is_new_branch" = true ]; then
        if ! git worktree add "$worktree_path" -b "$branch_name"; then
            log_error "Failed to create worktree with new branch '$branch_name'"
            log_info "Git error shown above"
            exit 1
        fi
    else
        # Check if branch is already checked out in another worktree
        if git worktree list | grep -q "$branch_name"; then
            log_error "Branch '$branch_name' is already checked out in another worktree"
            log_info "Hint: Use a different branch or topic name"
            exit 1
        fi

        if ! git worktree add "$worktree_path" "$branch_name"; then
            log_error "Failed to create worktree for branch '$branch_name'"
            log_info "Git error shown above"
            exit 1
        fi
    fi

    log_success "Worktree created"

    # Step 6: Create session and metadata
    create_session_and_metadata "$session_name" "$repo_name" "$topic" \
        "$branch_name" "$worktree_path" "$repo_path"
}

# Create tmux session and save metadata
create_session_and_metadata() {
    local session_name="$1"
    local repo_name="$2"
    local topic="$3"
    local branch_name="$4"
    local worktree_path="$5"
    local repo_path="$6"

    # Determine if we should launch agent
    local auto_agent="${WORKTREE_AUTO_AGENT:-on}"
    local launch_agent=false
    local agent_cmd=""

    case "$auto_agent" in
        on|prompt)
            # Show fzf agent picker
            if agent_cmd=$(select_agent) && [ -n "$agent_cmd" ]; then
                launch_agent=true
            else
                launch_agent=false
                agent_cmd=""
            fi
            ;;
        off)
            launch_agent=false
            agent_cmd=""
            ;;
    esac

    # Create tmux session
    log_info "Creating tmux session: $session_name"
    create_tmux_session "$session_name" "$worktree_path" "$launch_agent" "$agent_cmd"

    # Save metadata
    local agent_available=false
    if [ -n "$agent_cmd" ]; then
        agent_available=true
    fi
    save_session "$session_name" "$repo_name" "$topic" "$branch_name" \
        "$worktree_path" "$repo_path" "$agent_available" "" "$agent_cmd"

    log_success "Session created: $session_name"

    # Switch to session
    switch_to_session "$session_name"
}

# Run main
main "$@"
