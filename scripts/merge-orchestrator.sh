#!/usr/bin/env bash

# Sends a prompt to the current pane's agent to review broadcasts,
# fact-check completed tasks, and merge branches in dependency order

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"

# Build the merge prompt dynamically with current state
build_merge_prompt() {
    local repo_path="$1"
    local repo_name="$2"

    local shared_dir
    shared_dir="$(expand_tilde "${WORKTREE_PATH:-$HOME/.worktrees}")/${repo_name}/.shared"

    # Detect base branch for this repo
    local base_branch
    base_branch=$(get_default_branch "$repo_path")

    # Collect active sessions with work to review
    local branch_status=""
    local broadcasts=""
    local has_work=false
    local sessions
    sessions=$(find_sessions_by_repo "$repo_name" 2>/dev/null)
    if [ -n "$sessions" ]; then
        while IFS= read -r session; do
            [ -z "$session" ] && continue
            local branch wt_path topic
            branch=$(get_session_field "$session" "branch")
            wt_path=$(get_session_field "$session" "worktree_path")
            topic=$(get_session_field "$session" "topic")

            # Check if branch has actual commits ahead of base branch
            local has_commits="no"
            local merged="no"
            if [ -n "$branch" ]; then
                cd "$repo_path" 2>/dev/null
                local ahead
                ahead=$(git log --oneline "${base_branch}..${branch}" 2>/dev/null | wc -l | tr -d ' ')
                if [ "$ahead" -gt 0 ]; then
                    has_commits="yes"
                    if git branch --merged "$base_branch" 2>/dev/null | sed 's/^[*+ ] //' | grep -qx "$branch"; then
                        merged="yes"
                    fi
                fi
            fi

            local has_uncommitted="no"
            if [ -d "$wt_path" ]; then
                cd "$wt_path" 2>/dev/null
                if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
                    has_uncommitted="yes"
                fi
            fi

            # Only include sessions that have commits or uncommitted work
            if [ "$has_commits" = "yes" ] || [ "$has_uncommitted" = "yes" ]; then
                has_work=true
            fi

            branch_status+="  - $session | branch: $branch | commits: $has_commits | merged: $merged | uncommitted: $has_uncommitted
"
            # Attach broadcast if one exists for this task
            local sanitized_topic
            sanitized_topic=$(echo "$topic" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
            for f in "$shared_dir/broadcasts"/*.md; do
                [ -f "$f" ] || continue
                local broadcast_id
                broadcast_id=$(basename "$f" .md)
                local sanitized_bid
                sanitized_bid=$(echo "$broadcast_id" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
                if [ "$sanitized_topic" = "$sanitized_bid" ]; then
                    broadcasts+="
--- ${broadcast_id} broadcast ---
$(cat "$f")
"
                    break
                fi
            done
        done <<< "$sessions"
    fi

    if [ "$has_work" = false ]; then
        echo ""
        return 1
    fi

    cat <<PROMPT
Review the completed task broadcasts and merge their branches into ${base_branch} in the correct dependency order.

## Current State

**Repo**: ${repo_name}
**Repo path**: ${repo_path}
**Shared dir**: ${shared_dir}

### Sessions & Branches
${branch_status}
### Broadcasts
${broadcasts}

## Your Job

1. **Read each broadcast** to understand what was changed
2. **Read the task.md** (in the repo root) to understand dependency order (\`**Depends On**\` / \`**Blocks**\` fields)
3. **For each completed task** (has a broadcast), in dependency order:
   a. Check if the worktree has uncommitted changes — if so, review and commit them first
   b. Fact-check: \`git diff ${base_branch}\` on the worktree branch and verify it matches the broadcast claims
   c. If correct, merge: \`git merge <branch> --no-edit\` from ${base_branch}
   d. If incorrect or suspicious, skip it and explain why
4. **After merging**, kill completed sessions with the plugin's kill script or tmux kill-session
5. **Report** what was merged, what was skipped, and what's still pending

## Rules
- Merge in dependency order: if TASK-B depends on TASK-A, merge A first
- Do NOT merge tasks that have uncommitted changes without reviewing them first
- Do NOT merge tasks whose broadcasts don't match the actual diff
- If a merge has conflicts, stop and report — do not force resolve
- Update task.md status to \`[x] done\` for successfully merged tasks
PROMPT
}

main() {
    local current_session
    current_session=$(get_current_session 2>/dev/null)

    if [ -z "$current_session" ]; then
        log_error "Not in a tmux session"
        exit 1
    fi

    local pane_id
    pane_id=$(tmux display-message -p '#{pane_id}')

    local pane_pid
    pane_pid=$(tmux display-message -p '#{pane_pid}')

    local agent_cmd="${WORKTREE_AGENT_CMD:-claude}"
    local agent_process="${agent_cmd%% *}"

    local has_agent=false
    if find_agent_pid "$pane_pid" "$agent_process" >/dev/null 2>&1; then
        has_agent=true
    fi

    if [ "$has_agent" = false ]; then
        log_warn "No agent process detected in current pane"
        echo "Send prompt anyway? (y/N)"
        local response
        read -r response </dev/tty 2>/dev/null || read -r response
        case "$response" in
            [yY]|[yY][eE][sS]) ;;
            *) exit 0 ;;
        esac
    fi

    # Get repo info from the pane's working directory (run-shell doesn't inherit pane cwd)
    local pane_cwd
    pane_cwd=$(tmux display-message -p '#{pane_current_path}')

    local repo_path repo_name
    repo_path=$(cd "$pane_cwd" && git rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$repo_path" ]; then
        log_error "Not in a git repository"
        exit 1
    fi
    repo_name=$(get_repo_name "$repo_path")

    # Build the prompt
    local prompt
    prompt=$(build_merge_prompt "$repo_path" "$repo_name")

    if [ -z "$prompt" ]; then
        log_warn "No sessions have commits or uncommitted work"
        log_info "Nothing to merge"
        sleep 1.5
        exit 0
    fi

    # Send to agent
    local tmpfile
    tmpfile=$(mktemp)
    echo "$prompt" > "$tmpfile"

    tmux load-buffer "$tmpfile"
    tmux paste-buffer -t "$pane_id"
    tmux send-keys -t "$pane_id" C-m

    rm -f "$tmpfile"

    log_success "Merge orchestrator prompt sent to agent"
}

main "$@"
