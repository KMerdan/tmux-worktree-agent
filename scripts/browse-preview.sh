#!/usr/bin/env bash

# Preview script for browse-sessions.sh fzf --preview
# Args: $1=session_name $2=type $3=repo_path

SESSION="$1"
TYPE="$2"
REPO_PATH="$3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"
source "$SCRIPT_DIR/status-agents.sh"

DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

human_time_ago() {
    local created="$1"
    [ -z "$created" ] && echo "?" && return
    local created_epoch now_epoch diff
    created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" +%s 2>/dev/null \
        || date -d "$created" +%s 2>/dev/null) || { echo "?"; return; }
    now_epoch=$(date +%s)
    diff=$((now_epoch - created_epoch))
    if [ $diff -lt 60 ]; then echo "just now"
    elif [ $diff -lt 3600 ]; then echo "$((diff / 60))m ago"
    elif [ $diff -lt 86400 ]; then echo "$((diff / 3600))h ago"
    else echo "$((diff / 86400))d ago"
    fi
}

# ── Render: project header ──────────────────────────────────────────────

render_project() {
    local repo_name="${SESSION:-${REPO_PATH##*/}}"

    echo -e "${BOLD}${repo_name}${NC}"
    echo -e "${DIM}${REPO_PATH}${NC}"

    # Session summary
    local total=0 cp=0 ca=0 co=0 cd=0
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        total=$((total + 1))
        local st
        st=$(agent_status_icon "$s")
        case "$st" in prompt) cp=$((cp+1)) ;; active) ca=$((ca+1)) ;; off) co=$((co+1)) ;; dead) cd=$((cd+1)) ;; esac
    done < <(find_sessions_by_repo "$repo_name")

    echo ""
    if [ $total -eq 0 ]; then
        echo -e "${DIM}No sessions${NC}"
    else
        echo -e "${BOLD}${total}${NC} sessions"
        [ $cp -gt 0 ] && echo -e "  ${YELLOW}⏎ ${cp} need attention${NC}"
        [ $ca -gt 0 ] && echo -e "  ${GREEN}● ${ca} working${NC}"
        [ $co -gt 0 ] && echo -e "  ${DIM}◌ ${co} idle${NC}"
        [ $cd -gt 0 ] && echo -e "  ${RED}✗ ${cd} dead${NC}"
    fi
}

# ── Render: untracked project ───────────────────────────────────────────

render_untracked() {
    echo -e "${BOLD}${SESSION}${NC}"
    echo -e "${DIM}${REPO_PATH}${NC}"
    echo ""
    echo -e "${DIM}No sessions yet${NC}"
    echo -e "${DIM}Enter to initialize · ^N to create first session${NC}"
}

# ── Render: session / subtask ───────────────────────────────────────────

render_session() {
    [ -z "$SESSION" ] && return

    # Status
    status=$(agent_status_icon "$SESSION")
    status_label=""
    case "$status" in
        prompt) status_label="${YELLOW}⏎ needs input${NC}" ;;
        active) status_label="${GREEN}● working${NC}" ;;
        off)    status_label="${DIM}◌ idle${NC}" ;;
        dead)   status_label="${RED}✗ dead${NC}" ;;
    esac

    # Metadata
    branch=$(get_session_field "$SESSION" "branch")
    agent_cmd=$(get_session_field "$SESSION" "agent_cmd")
    created=$(get_session_field "$SESSION" "created_at")
    worktree_path=$(get_session_field "$SESSION" "worktree_path")
    description=$(get_session_field "$SESSION" "description")
    time_ago=$(human_time_ago "$created")

    # ── Line 1: name + status
    echo -e "${BOLD}${SESSION}${NC}  ${status_label}"

    # ── Line 2: branch · agent · age
    meta=""
    [ -n "$branch" ] && meta+="${branch}"
    [ -n "$agent_cmd" ] && meta+="${meta:+ · }${agent_cmd}"
    [ -n "$time_ago" ] && meta+="${meta:+ · }${time_ago}"
    echo -e "${DIM}${meta}${NC}"

    # ── Task context (if wt-*.md exists) ──
    task_file=""
    if [ -n "$worktree_path" ] && [ -d "$worktree_path" ]; then
        for f in "$worktree_path"/wt-*.md; do
            [ -f "$f" ] && task_file="$f" && break
        done
    fi

    if [ -n "$task_file" ]; then
        render_task_context "$task_file"
    elif [ -n "$description" ]; then
        echo -e "${DIM}─────────────────────────────────${NC}"
        echo -e "${DIM}${description}${NC}"
    fi

    # ── Terminal output (always) ──
    echo -e "${DIM}─────────────────────────────────${NC}"
    render_terminal
}

# ── Parse task markdown into clean fields ───────────────────────────────

render_task_context() {
    local file="$1"

    # Extract the task block (after first ---)
    local block
    block=$(awk '/^---[[:space:]]*$/ { found=1; next } found { print }' "$file")

    [ -z "$block" ] && return

    # Parse structured fields from the block
    local task_id title priority status_field depends
    task_id=$(echo "$block" | grep -m1 '^### Task ID:' | sed 's/^### Task ID:[[:space:]]*//')
    title=$(echo "$block" | grep -m1 '^\*\*Title\*\*:' | sed 's/^\*\*Title\*\*:[[:space:]]*//')
    priority=$(echo "$block" | grep -m1 '^\*\*Priority\*\*:' | sed 's/^\*\*Priority\*\*:[[:space:]]*//')
    depends=$(echo "$block" | grep -m1 '^\*\*Depends On\*\*:' | sed 's/^\*\*Depends On\*\*:[[:space:]]*//')

    echo -e "${DIM}─────────────────────────────────${NC}"

    # Compact task header
    [ -n "$task_id" ] && echo -e "${CYAN}${task_id}${NC}${priority:+  ${DIM}[${priority}]${NC}}"
    [ -n "$title" ] && echo -e "${BOLD}${title}${NC}"
    [ -n "$depends" ] && [ "$depends" != "None" ] && [ "$depends" != "none" ] && \
        echo -e "${DIM}← ${depends}${NC}"

    # Body: everything after the structured fields (skip blank lines at start)
    local body
    body=$(echo "$block" | awk '
        /^### Task ID:|^\*\*Title\*\*:|^\*\*Status\*\*:|^\*\*Priority\*\*:|^\*\*Depends On\*\*:|^\*\*Blocks\*\*:/ { next }
        /^[[:space:]]*$/ { if (!started) next; }
        { started=1; print }
    ' | head -6)

    if [ -n "$body" ]; then
        echo -e "${DIM}${body}${NC}"
    fi
}

# ── Terminal capture ────────────────────────────────────────────────────

render_terminal() {
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
        echo -e "${DIM}session not running${NC}"
        return
    fi

    captured=$(tmux capture-pane -t "$SESSION" -p 2>/dev/null | grep -v '^$' | tail -20)
    if [ -n "$captured" ]; then
        echo "$captured"
    else
        echo -e "${DIM}(no output)${NC}"
    fi
}

# ── Dispatch ────────────────────────────────────────────────────────────

case "$TYPE" in
    project)         render_project ;;
    untracked)       render_untracked ;;
    session|subtask) render_session ;;
    separator)       ;;
esac
