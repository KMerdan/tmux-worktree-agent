#!/usr/bin/env bash

# Get script directory and source utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"

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

    # Step 2: Get branch name
    if [ "$QUICK_MODE" = true ]; then
        # Quick mode: use current branch
        branch_name=$(get_current_branch)

        if [ -z "$branch_name" ] || [ "$branch_name" = "HEAD" ]; then
            log_error "Not on a valid branch. Use full create mode (prefix + C-w)"
            exit 1
        fi

        log_info "Creating worktree from current branch: $branch_name"
    else
        # Full mode: prompt for branch
        echo "=== Create Worktree Session ==="
        echo ""

        # Get list of branches for autocomplete hint
        local branches
        branches=$(cd "$repo_path" && git branch --format='%(refname:short)' | head -5)

        echo "Existing branches (showing first 5):"
        echo "$branches"
        echo ""

        branch_name=$(prompt "Branch name")

        if [ -z "$branch_name" ]; then
            log_error "Branch name required"
            echo ""
            echo "Press Enter to close..."
            read -r
            exit 1
        fi

        log_info "Branch name entered: $branch_name"

        # Check if branch exists
        if ! cd "$repo_path" && git rev-parse --verify "$branch_name" >/dev/null 2>&1; then
            if confirm "Branch '$branch_name' doesn't exist. Create new branch?"; then
                is_new_branch=true
            else
                log_info "Cancelled"
                exit 0
            fi
        fi
    fi

    # Step 3: Get topic/description
    topic=$(prompt "Topic/description")

    if [ -z "$topic" ]; then
        log_error "Topic required"
        echo ""
        echo "Press Enter to close..."
        read -r
        exit 1
    fi

    log_info "Topic entered: $topic"

    # Sanitize topic for use in paths
    topic=$(sanitize_name "$topic")
    log_info "Sanitized topic: $topic"

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

    case "$auto_agent" in
        on)
            launch_agent=true
            ;;
        off)
            launch_agent=false
            ;;
        prompt)
            if confirm "Launch agent (${WORKTREE_AGENT_CMD:-claude})?"; then
                launch_agent=true
            fi
            ;;
    esac

    # Check if agent command exists
    local agent_cmd="${WORKTREE_AGENT_CMD:-claude}"
    local agent_available=false

    if command_exists "${agent_cmd%% *}"; then
        agent_available=true
    else
        log_warn "Agent command '$agent_cmd' not found"

        if [ "$auto_agent" = "prompt" ]; then
            if ! confirm "Create session without agent?"; then
                log_info "Cancelled"
                exit 0
            fi
        fi

        launch_agent=false
    fi

    # Create tmux session
    log_info "Creating tmux session: $session_name"
    create_tmux_session "$session_name" "$worktree_path" "$launch_agent"

    # Save metadata
    save_session "$session_name" "$repo_name" "$topic" "$branch_name" \
        "$worktree_path" "$repo_path" "$agent_available"

    log_success "Session created: $session_name"

    # Switch to session
    switch_to_session "$session_name"
}

# Run main with error handling
if ! main "$@"; then
    echo ""
    echo "Press Enter to close..."
    read -r
    exit 1
fi
