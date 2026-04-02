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

case "$TYPE" in
    project)
        # Get repo name from metadata
        repo_name="$SESSION"
        [ -z "$repo_name" ] && repo_name="${REPO_PATH##*/}"

        echo -e "${BOLD}${repo_name}${NC}"
        echo -e "${DIM}${REPO_PATH}${NC}"
        echo ""

        count=0
        while IFS= read -r s; do
            [ -z "$s" ] && continue
            [[ "$s" == *-hub ]] && continue
            count=$((count + 1))
        done < <(find_sessions_by_repo "$repo_name")
        echo -e "Sessions: ${count}"
        ;;

    untracked)
        echo -e "${BOLD}${SESSION}${NC}"
        echo -e "${DIM}${REPO_PATH}${NC}"
        echo ""
        echo -e "${DIM}No sessions yet${NC}"
        echo -e "${DIM}Press Enter to initialize${NC}"
        ;;

    session|subtask)
        [ -z "$SESSION" ] && exit 0

        # Header
        status=$(agent_status_icon "$SESSION")
        branch=$(get_session_field "$SESSION" "branch")
        agent_cmd=$(get_session_field "$SESSION" "agent_cmd")
        created=$(get_session_field "$SESSION" "created_at")

        status_label=""
        case "$status" in
            prompt) status_label="${YELLOW}⏎ needs input${NC}" ;;
            active) status_label="${GREEN}● working${NC}" ;;
            off)    status_label="${DIM}◌ idle${NC}" ;;
            dead)   status_label="${RED}✗ dead${NC}" ;;
        esac

        time_ago=$(human_time_ago "$created")

        echo -e "${BOLD}${SESSION}${NC}  ${status_label}"
        meta_parts=()
        [ -n "$branch" ] && meta_parts+=("$branch")
        [ -n "$agent_cmd" ] && meta_parts+=("$agent_cmd")
        [ -n "$time_ago" ] && meta_parts+=("$time_ago")
        echo -e "${DIM}$(IFS=' · '; echo "${meta_parts[*]}")${NC}"

        # Task context
        worktree_path=$(get_session_field "$SESSION" "worktree_path")
        has_context=false

        if [ -n "$worktree_path" ] && [ -d "$worktree_path" ]; then
            task_file=""
            for f in "$worktree_path"/wt-*.md; do
                [ -f "$f" ] && task_file="$f" && break
            done
            if [ -n "$task_file" ]; then
                echo -e "${DIM}───────────────────────────────────${NC}"
                awk '/^---[[:space:]]*$/ { found=1; next } found { print }' "$task_file" | head -8
                has_context=true
            fi
        fi

        if [ "$has_context" != true ]; then
            description=$(get_session_field "$SESSION" "description")
            if [ -n "$description" ]; then
                echo -e "${DIM}───────────────────────────────────${NC}"
                echo "$description"
            fi
        fi

        # Terminal output
        echo -e "${DIM}───────────────────────────────────${NC}"
        if tmux has-session -t "$SESSION" 2>/dev/null; then
            captured=$(tmux capture-pane -t "$SESSION" -p 2>/dev/null | grep -v '^$' | tail -20)
            if [ -n "$captured" ]; then
                echo "$captured"
            else
                echo -e "${DIM}(no output)${NC}"
            fi
        else
            echo -e "${DIM}session not running${NC}"
        fi
        ;;

    separator)
        echo ""
        ;;
esac
