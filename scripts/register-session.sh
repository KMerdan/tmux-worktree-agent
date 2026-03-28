#!/usr/bin/env bash

# Register the current tmux session into plugin metadata
# Does nothing if already registered

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"

trap 'rc=$?; if [ $rc -ne 0 ]; then sleep 1.5; fi; exit $rc' EXIT

main() {
    local session_name
    session_name=$(get_current_session 2>/dev/null)

    if [ -z "$session_name" ]; then
        log_error "Not in a tmux session"
        exit 1
    fi

    # Already registered — do nothing
    if session_in_metadata "$session_name"; then
        log_info "Session '$session_name' is already registered"
        sleep 1
        exit 0
    fi

    # Detect context from the pane's working directory
    local pane_cwd
    pane_cwd=$(tmux display-message -p '#{pane_current_path}')

    local repo_path=""
    local branch=""
    local repo_name=""

    if cd "$pane_cwd" && git rev-parse --show-toplevel >/dev/null 2>&1; then
        repo_path=$(git rev-parse --show-toplevel)
        branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        repo_name=$(get_repo_name "$repo_path")
    fi

    # Determine if this is a git worktree (not the main repo)
    local worktree_path=""
    if [ -n "$repo_path" ]; then
        local git_common_dir
        git_common_dir=$(cd "$repo_path" && git rev-parse --git-common-dir 2>/dev/null)
        local git_dir
        git_dir=$(cd "$repo_path" && git rev-parse --git-dir 2>/dev/null)

        # If git-common-dir != git-dir, we're in a worktree
        if [ -n "$git_common_dir" ] && [ -n "$git_dir" ] && [ "$git_common_dir" != "$git_dir" ]; then
            worktree_path="$repo_path"
        else
            worktree_path="$pane_cwd"
        fi
    else
        worktree_path="$pane_cwd"
    fi

    # Derive main repo path from git common dir
    local main_repo_path=""
    if [ -n "$repo_path" ]; then
        local common_dir
        common_dir=$(cd "$repo_path" && git rev-parse --git-common-dir 2>/dev/null)
        if [ -n "$common_dir" ] && [ "$common_dir" != ".git" ]; then
            # common_dir is something like /path/to/main-repo/.git
            main_repo_path=$(dirname "$common_dir")
        else
            main_repo_path="$repo_path"
        fi
    fi

    # Detect running agent
    local agent_cmd=""
    local pane_pid
    pane_pid=$(tmux display-message -p '#{pane_pid}')

    local agent_list="${WORKTREE_AGENT_LIST:-claude}"
    IFS=',' read -ra agents <<< "$agent_list"
    for agent in "${agents[@]}"; do
        agent=$(echo "$agent" | xargs)
        if find_agent_pid "$pane_pid" "$agent" >/dev/null 2>&1; then
            agent_cmd="$agent"
            break
        fi
    done

    # Use topic from session name or branch
    local topic
    topic=$(echo "$session_name" | sed "s/^${repo_name}-//" 2>/dev/null)
    if [ -z "$topic" ] || [ "$topic" = "$session_name" ]; then
        topic=$(sanitize_name "${branch:-$session_name}")
    fi

    # Show what we detected
    echo "=== Register Session ==="
    echo ""
    log_info "Session:  $session_name"
    [ -n "$repo_name" ]      && log_info "Repo:     $repo_name"
    [ -n "$branch" ]         && log_info "Branch:   $branch"
    [ -n "$worktree_path" ]  && log_info "Path:     $worktree_path"
    [ -n "$agent_cmd" ]      && log_info "Agent:    $agent_cmd"
    echo ""

    # If session name looks auto-generated (numeric), ask for a proper name
    local new_name=""
    if [[ "$session_name" =~ ^[0-9]+$ ]]; then
        local suggested=""
        if [ -n "$repo_name" ] && [ -n "$branch" ]; then
            suggested=$(generate_session_name "$repo_name" "$(sanitize_name "$branch")")
        fi

        new_name=$(prompt "Session name" "$suggested")

        if [ -z "$new_name" ]; then
            log_error "Session name required"
            exit 1
        fi

        # Check the new name isn't already taken
        if session_exists "$new_name" || session_in_metadata "$new_name"; then
            log_error "Session '$new_name' already exists"
            exit 1
        fi

        # Rename the tmux session
        tmux rename-session -t "$session_name" "$new_name"
        session_name="$new_name"
        log_success "Session renamed to: $session_name"
        echo ""
    fi

    # Recalculate topic from (possibly new) session name
    topic=$(echo "$session_name" | sed "s/^${repo_name}-//" 2>/dev/null)
    if [ -z "$topic" ] || [ "$topic" = "$session_name" ]; then
        topic=$(sanitize_name "${branch:-$session_name}")
    fi

    if ! confirm "Register this session?"; then
        log_info "Cancelled"
        exit 0
    fi

    local agent_running=false
    if [ -n "$agent_cmd" ]; then
        agent_running=true
    fi

    # Detect parent branch from main repo
    local parent_branch=""
    if [ -n "$main_repo_path" ] && [ -d "$main_repo_path" ]; then
        parent_branch=$(cd "$main_repo_path" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
    fi

    save_session "$session_name" \
        "${repo_name:-unknown}" \
        "$topic" \
        "${branch:-unknown}" \
        "$worktree_path" \
        "${main_repo_path:-$worktree_path}" \
        "$agent_running" \
        "" \
        "$agent_cmd" \
        "$parent_branch"

    log_success "Session '$session_name' registered"
    sleep 1
}

main "$@"
