#!/usr/bin/env bash

# Sends a prompt to the current pane's agent to load its task and
# fact-check before implementing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"

trap 'rc=$?; if [ $rc -ne 0 ]; then sleep 1.5; fi; exit $rc' EXIT

TASK_PROMPT='Load the task and understand it fully before writing any code.

1. Read your task file and `.shared/context.md` to understand the full scope
2. Check `.shared/broadcasts/` for updates from other agents working on parallel tasks
3. Fact-check every assumption against the actual codebase — read the relevant files, trace the code paths, verify interfaces and types exist as described
4. Only after you have confirmed your understanding matches reality, begin implementing'

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

    local tmpfile
    tmpfile=$(mktemp)
    echo "$TASK_PROMPT" > "$tmpfile"

    tmux load-buffer "$tmpfile"
    tmux paste-buffer -t "$pane_id"
    tmux send-keys -t "$pane_id" C-m

    rm -f "$tmpfile"

    log_success "Start task prompt sent to agent"
    sleep 1
}

main "$@"
