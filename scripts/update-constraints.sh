#!/usr/bin/env bash

# Sends a prompt to the current pane's agent to review and update
# task.md shared constraints based on recent changes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"

trap 'rc=$?; if [ $rc -ne 0 ]; then sleep 1.5; fi; exit $rc' EXIT

build_update_prompt() {
    local repo_path="$1"

    # Get recent git history to show what's changed
    local recent_changes
    recent_changes=$(cd "$repo_path" && git log --oneline -20 2>/dev/null)

    local changed_files
    changed_files=$(cd "$repo_path" && git log --name-only --pretty=format: -20 2>/dev/null | sort -u | grep -v '^$')

    cat <<PROMPT
Review and update the \`task.md\` file in the repo root. The shared constraints section may be stale — files listed as "do not modify" may have been heavily modified since the task.md was written.

## Recent Git History
\`\`\`
${recent_changes}
\`\`\`

## Files Changed Recently
\`\`\`
${changed_files}
\`\`\`

## Your Job

1. Read the \`## Shared Constraints\` section in task.md
2. For each "Do NOT modify" constraint, check if that file has been modified in recent commits
3. If a constraint is stale (the file has been actively modified), either:
   - Remove the constraint if the file is now stable and open for changes
   - Update the constraint to reflect the current state (e.g., "Do NOT modify X except for Y")
4. Check if any task's \`**Scoped Files**\` conflicts with the shared constraints — flag these
5. Also update the \`## Cross-Task Dependencies\` section:
   - Mark completed tasks (check \`**Status**: [x] done\`)
   - Update dependency notes for remaining tasks

## Rules
- Only modify the preamble (before the first \`---\`), not individual task blocks
- Keep constraints that are still valid
- Be specific about what changed and why a constraint was removed/updated
- Do NOT change task IDs, titles, or acceptance criteria
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

    # Get repo info from pane's cwd
    local pane_cwd
    pane_cwd=$(tmux display-message -p '#{pane_current_path}')

    local repo_path
    repo_path=$(cd "$pane_cwd" && git rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$repo_path" ]; then
        log_error "Not in a git repository"
        exit 1
    fi

    local prompt
    prompt=$(build_update_prompt "$repo_path")

    local tmpfile
    tmpfile=$(mktemp)
    echo "$prompt" > "$tmpfile"

    tmux load-buffer "$tmpfile"
    tmux paste-buffer -t "$pane_id"
    tmux send-keys -t "$pane_id" C-m

    rm -f "$tmpfile"

    log_success "Update constraints prompt sent to agent"
    sleep 1
}

main "$@"
