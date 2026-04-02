#!/usr/bin/env bash

# Dashboard — persistent session as multi-agent workflow home base
# Subcommands: open, fzf-loop, preview-loop, list

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"
source "$SCRIPT_DIR/status-agents.sh"

# ── Helpers ──────────────────────────────────────────────────────────────

DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

status_sort_key() {
    case "$1" in
        prompt) echo 0 ;;
        dead)   echo 1 ;;
        active) echo 2 ;;
        off)    echo 3 ;;
        *)      echo 9 ;;
    esac
}

status_display_icon() {
    case "$1" in
        prompt) printf "${YELLOW}⏎${NC}" ;;
        active) printf "${GREEN}●${NC}" ;;
        dead)   printf "${RED}✗${NC}" ;;
        off)    printf "${DIM}◌${NC}" ;;
        *)      printf "${DIM}?${NC}" ;;
    esac
}

agent_display_icon() {
    local agent="$1"
    if [ -n "$agent" ]; then
        printf "${CYAN}●${NC}"
    else
        printf "${DIM}○${NC}"
    fi
}

status_group_label() {
    case "$1" in
        prompt) echo -e "${YELLOW}${BOLD} need attention${NC}" ;;
        dead)   echo -e "${RED}${BOLD} dead${NC}" ;;
        active) echo -e "${DIM}── working ──────────────────${NC}" ;;
        off)    echo -e "${DIM}── idle ─────────────────────${NC}" ;;
    esac
}

human_time_ago() {
    local created="$1"
    [ -z "$created" ] && echo "?" && return
    local created_epoch now_epoch diff
    created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created" +%s 2>/dev/null || date -d "$created" +%s 2>/dev/null) || { echo "?"; return; }
    now_epoch=$(date +%s)
    diff=$((now_epoch - created_epoch))
    if [ $diff -lt 60 ]; then echo "just now"
    elif [ $diff -lt 3600 ]; then echo "$((diff / 60))m ago"
    elif [ $diff -lt 86400 ]; then echo "$((diff / 3600))h ago"
    else echo "$((diff / 86400))d ago"
    fi
}

# ── build_dashboard_lines ────────────────────────────────────────────────

build_dashboard_lines() {
    local repo_name="$1"
    local hub_name="${repo_name}-hub"

    local sessions
    sessions=$(find_sessions_by_repo "$repo_name")

    local lines=()
    local count_prompt=0 count_active=0 count_off=0 count_dead=0

    while IFS= read -r session; do
        [ -z "$session" ] && continue
        # Skip the hub session itself
        [ "$session" = "$hub_name" ] && continue
        # Skip if session not in tmux and not in metadata
        local status
        status=$(agent_status_icon "$session")
        local agent_cmd branch description
        agent_cmd=$(get_session_field "$session" "agent_cmd")
        branch=$(get_session_field "$session" "branch")
        description=$(get_session_field "$session" "description")

        local sort_key
        sort_key=$(status_sort_key "$status")

        case "$status" in
            prompt) ((count_prompt++)) ;;
            active) ((count_active++)) ;;
            off)    ((count_off++)) ;;
            dead)   ((count_dead++)) ;;
        esac

        # Truncate for display
        local short_branch="${branch:0:22}"
        local short_desc="${description:0:30}"
        local agent_name="${agent_cmd:-─}"
        agent_name="${agent_name:0:8}"

        local s_icon a_icon
        s_icon=$(status_display_icon "$status")
        a_icon=$(agent_display_icon "$agent_cmd")

        local display_line
        if [ -n "$description" ]; then
            display_line=$(printf " %b %b %-25s %-8s %-22s %b" "$s_icon" "$a_icon" "$session" "$agent_name" "$short_branch" "${DIM}${short_desc}${NC}")
        else
            display_line=$(printf " %b %b %-25s %-8s %-22s" "$s_icon" "$a_icon" "$session" "$agent_name" "$short_branch")
        fi

        lines+=("${sort_key}|${status}|${display_line}	${session}	${status}")
    done <<< "$sessions"

    # Sort by status priority
    IFS=$'\n' sorted=($(printf '%s\n' "${lines[@]}" | sort -t'|' -k1,1n))
    unset IFS

    # Header
    local header="${repo_name}-hub"
    local counts=""
    [ $count_prompt -gt 0 ] && counts+="⏎ ${count_prompt} need you"
    [ $count_active -gt 0 ] && { [ -n "$counts" ] && counts+=" · "; counts+="● ${count_active} working"; }
    [ $count_off -gt 0 ] && { [ -n "$counts" ] && counts+=" · "; counts+="◌ ${count_off} idle"; }
    [ $count_dead -gt 0 ] && { [ -n "$counts" ] && counts+=" · "; counts+="✗ ${count_dead} dead"; }
    [ -z "$counts" ] && counts="no sessions"

    echo -e "${BOLD}${header}${NC}"
    echo -e "${DIM}${counts}${NC}"
    echo -e "${DIM}─────────────────────────────────────────${NC}"

    if [ ${#sorted[@]} -eq 0 ]; then
        echo -e "${DIM}  No agent sessions yet. Press Ctrl-N to create one.${NC}"
        return
    fi

    local prev_group=""
    for entry in "${sorted[@]}"; do
        local group="${entry%%|*}"
        local rest="${entry#*|}"
        local status_val="${rest%%|*}"
        local line_data="${rest#*|}"

        if [ "$status_val" != "$prev_group" ]; then
            # Insert group separator (not for the first group — header serves as separator)
            if [ -n "$prev_group" ]; then
                echo -e "$(status_group_label "$status_val")"
            fi
            prev_group="$status_val"
        fi

        echo -e "$line_data"
    done
}

# ── Subcommand: list ─────────────────────────────────────────────────────

cmd_list() {
    local repo_path="$1"
    local repo_name
    repo_name=$(get_repo_name "$repo_path")
    build_dashboard_lines "$repo_name"
}

# ── Subcommand: preview-loop ────────────────────────────────────────────

cmd_preview_loop() {
    local repo_path="$1"
    local repo_name
    repo_name=$(get_repo_name "$repo_path")
    local selection_file="/tmp/wta-hub-${repo_name}.selection"

    local last_session=""

    while true; do
        local session=""
        if [ -f "$selection_file" ]; then
            session=$(cat "$selection_file" 2>/dev/null)
        fi

        # Only redraw if selection changed or on interval
        clear

        if [ -z "$session" ] || [ "$session" = "(none)" ]; then
            # Show repo summary
            local total=0 cp=0 ca=0 co=0 cd=0
            local sessions
            sessions=$(find_sessions_by_repo "$repo_name")
            while IFS= read -r s; do
                [ -z "$s" ] && continue
                [ "$s" = "${repo_name}-hub" ] && continue
                ((total++))
                local st
                st=$(agent_status_icon "$s")
                case "$st" in prompt) ((cp++));; active) ((ca++));; off) ((co++));; dead) ((cd++));; esac
            done <<< "$sessions"

            echo -e "${BOLD}${repo_name}${NC}"
            echo -e "───────────────────────────────────"
            echo -e "  Total sessions: ${total}"
            [ $cp -gt 0 ] && echo -e "  ${YELLOW}⏎ Need attention: ${cp}${NC}"
            [ $ca -gt 0 ] && echo -e "  ${GREEN}● Working: ${ca}${NC}"
            [ $co -gt 0 ] && echo -e "  ${DIM}◌ Idle: ${co}${NC}"
            [ $cd -gt 0 ] && echo -e "  ${RED}✗ Dead: ${cd}${NC}"
            echo ""
            echo -e "${DIM}Select a session to see details${NC}"
        else
            render_preview "$session"
        fi

        last_session="$session"
        sleep 3
    done
}

render_preview() {
    local session="$1"

    local branch agent_cmd status created worktree_path description
    branch=$(get_session_field "$session" "branch")
    agent_cmd=$(get_session_field "$session" "agent_cmd")
    status=$(agent_status_icon "$session")
    created=$(get_session_field "$session" "created_at")
    worktree_path=$(get_session_field "$session" "worktree_path")
    description=$(get_session_field "$session" "description")

    local status_label
    case "$status" in
        prompt) status_label="${YELLOW}⏎ Needs your input${NC}" ;;
        active) status_label="${GREEN}● Working${NC}" ;;
        off)    status_label="${DIM}◌ Idle${NC}" ;;
        dead)   status_label="${RED}✗ Not running${NC}" ;;
    esac

    local time_ago
    time_ago=$(human_time_ago "$created")

    # Box header
    echo -e "┌─ ${BOLD}${session}${NC} ────────────────────────┐"
    echo -e "│ Branch:  ${CYAN}${branch:-─}${NC}"
    echo -e "│ Agent:   ${agent_cmd:-─}"
    echo -e "│ Status:  ${status_label}"
    echo -e "│ Created: ${time_ago}"
    [ -n "$description" ] && echo -e "│ Desc:    ${DIM}${description:0:40}${NC}"
    echo -e "└─────────────────────────────────────────┘"

    # Terminal capture (last output)
    if [ "$status" != "dead" ] && tmux has-session -t "$session" 2>/dev/null; then
        echo ""
        echo -e "${BOLD}Last Output:${NC}"
        echo -e "${DIM}───────────────────────────────────────${NC}"
        local captured
        captured=$(tmux capture-pane -t "$session" -p 2>/dev/null | grep -v '^$' | tail -12)
        if [ -n "$captured" ]; then
            echo "$captured"
        else
            echo -e "${DIM}  (no output)${NC}"
        fi
    fi

    # Git status
    if [ -n "$worktree_path" ] && [ -d "$worktree_path" ]; then
        local git_status
        git_status=$(git -C "$worktree_path" status --short 2>/dev/null)
        if [ -n "$git_status" ]; then
            local file_count
            file_count=$(echo "$git_status" | wc -l | tr -d ' ')
            echo ""
            echo -e "${BOLD}Git: ${file_count} files changed${NC}"
            echo -e "${DIM}───────────────────────────────────────${NC}"
            echo "$git_status" | head -10
            [ "$file_count" -gt 10 ] && echo -e "${DIM}  ... and $((file_count - 10)) more${NC}"
        fi

        # Recent commits
        local commits
        commits=$(git -C "$worktree_path" log --oneline -5 2>/dev/null)
        if [ -n "$commits" ]; then
            echo ""
            echo -e "${BOLD}Commits:${NC}"
            echo -e "${DIM}───────────────────────────────────────${NC}"
            echo "$commits"
        fi
    fi
}

# ── Subcommand: fzf-loop ────────────────────────────────────────────────

cmd_fzf_loop() {
    local repo_path="$1"
    local repo_name
    repo_name=$(get_repo_name "$repo_path")
    local selection_file="/tmp/wta-hub-${repo_name}.selection"

    trap "rm -f '$selection_file'" EXIT

    while true; do
        local list_output
        list_output=$(build_dashboard_lines "$repo_name")

        if [ -z "$list_output" ]; then
            list_output="No sessions found"
        fi

        local result
        result=$(echo "$list_output" | fzf \
            --ansi \
            --no-sort \
            --layout=reverse \
            --no-info \
            --header-first \
            --header="Enter:jump ^N:create ^T:tasks ^G:prompts ^D:kill ^R:refresh" \
            --prompt="" \
            --pointer="▸" \
            --delimiter=$'\t' \
            --with-nth=1 \
            --height=100% \
            --expect=enter \
            --bind "focus:execute-silent(echo {2} > '$selection_file')" \
            --bind "ctrl-n:execute(tmux display-popup -E -w 85% -h 85% -d '$repo_path' '$SCRIPT_DIR/create-worktree.sh')+reload(bash '$SCRIPT_DIR/dashboard.sh' list '$repo_path')" \
            --bind "ctrl-t:execute(tmux display-popup -E -w 95% -h 95% -d '$repo_path' '$SCRIPT_DIR/task-selector.sh')+reload(bash '$SCRIPT_DIR/dashboard.sh' list '$repo_path')" \
            --bind "ctrl-g:execute(tmux display-popup -E -w 95% -h 95% -d '$repo_path' '$SCRIPT_DIR/task-prompt-menu.sh')" \
            --bind "ctrl-d:execute(tmux display-popup -E -w 85% -h 85% '$SCRIPT_DIR/kill-worktree.sh' {2})+reload(bash '$SCRIPT_DIR/dashboard.sh' list '$repo_path')" \
            --bind "ctrl-r:reload(bash '$SCRIPT_DIR/dashboard.sh' list '$repo_path')" \
        ) || true

        # Parse expected key + selection
        local key selected_session
        key=$(echo "$result" | head -1)
        local selected_line
        selected_line=$(echo "$result" | tail -1)
        selected_session=$(echo "$selected_line" | awk -F'\t' '{print $2}')

        if [ "$key" = "enter" ] && [ -n "$selected_session" ]; then
            tmux switch-client -t "$selected_session" 2>/dev/null || true
        fi

        # If fzf was escaped or stdin closed, check if we should continue
        if [ ! -t 0 ]; then
            break
        fi

        # Small delay before re-rendering
        sleep 0.2
    done
}

# ── Subcommand: open ─────────────────────────────────────────────────────

cmd_open() {
    local repo_path="$1"

    # Detect repo path
    if [ -z "$repo_path" ]; then
        if [ -n "${TMUX:-}" ]; then
            repo_path=$(tmux display-message -p '#{pane_current_path}' 2>/dev/null)
        fi
    fi
    if [ -z "$repo_path" ]; then
        repo_path=$(pwd)
    fi

    # Resolve to git root
    repo_path=$(cd "$repo_path" && git rev-parse --show-toplevel 2>/dev/null) || {
        echo "Error: not in a git repository" >&2
        return 1
    }

    local repo_name
    repo_name=$(get_repo_name "$repo_path")
    local hub_name="${repo_name}-hub"

    # Check if we're already in the hub — toggle back
    if [ -n "${TMUX:-}" ]; then
        local current_session
        current_session=$(tmux display-message -p '#S' 2>/dev/null)
        if [ "$current_session" = "$hub_name" ]; then
            tmux switch-client -l 2>/dev/null || true
            return 0
        fi
    fi

    # Check if hub session already exists
    if tmux has-session -t "$hub_name" 2>/dev/null; then
        # Check if dashboard window exists
        if tmux list-windows -t "$hub_name" -F '#{window_name}' 2>/dev/null | grep -q '^dashboard$'; then
            # Switch to existing dashboard
            if [ -z "${TMUX:-}" ]; then
                tmux attach-session -t "$hub_name"
            else
                tmux switch-client -t "$hub_name:dashboard"
            fi
            return 0
        fi

        # Hub exists but no dashboard window — create it
        setup_dashboard_window "$hub_name" "$repo_path"
        if [ -z "${TMUX:-}" ]; then
            tmux attach-session -t "$hub_name"
        else
            tmux switch-client -t "$hub_name:dashboard"
        fi
        return 0
    fi

    # Create new hub session
    tmux new-session -d -s "$hub_name" -c "$repo_path"
    setup_dashboard_window "$hub_name" "$repo_path"

    # Register in metadata
    save_session "$hub_name" "$repo_name" "hub" "" "" "$repo_path" false "Dashboard hub" "" "" ""

    # Attach/switch
    if [ -z "${TMUX:-}" ]; then
        tmux attach-session -t "$hub_name"
    else
        tmux switch-client -t "$hub_name:dashboard"
    fi
}

setup_dashboard_window() {
    local hub_name="$1"
    local repo_path="$2"

    # Rename the first window (or create one)
    local first_window
    first_window=$(tmux list-windows -t "$hub_name" -F '#{window_id}' 2>/dev/null | head -1)
    if [ -n "$first_window" ]; then
        tmux rename-window -t "${hub_name}:${first_window}" "dashboard"
    fi

    # Set up layout: left pane (55%) runs fzf-loop, right pane (45%) runs preview-loop
    # Start with the fzf-loop in the current pane
    tmux send-keys -t "${hub_name}:dashboard" "bash '$SCRIPT_DIR/dashboard.sh' fzf-loop '$repo_path'" Enter

    # Split right for preview-loop (45%)
    tmux split-window -t "${hub_name}:dashboard" -h -l 45% -c "$repo_path" \
        "bash '$SCRIPT_DIR/dashboard.sh' preview-loop '$repo_path'"

    # Focus left pane (fzf)
    tmux select-pane -t "${hub_name}:dashboard.0"
}

# ── Dispatch ─────────────────────────────────────────────────────────────

case "${1:-open}" in
    open)         cmd_open "$2" ;;
    fzf-loop)     cmd_fzf_loop "$2" ;;
    preview-loop) cmd_preview_loop "$2" ;;
    list)         cmd_list "$2" ;;
    *)            cmd_open "$2" ;;
esac
