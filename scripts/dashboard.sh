#!/usr/bin/env bash

# Dashboard — Finder-style 4-column multi-agent workflow hub
#
# Layout:  Projects (15%) │ Sessions (20%) │ Sub-tasks (20%) │ Preview (45%)
#
# Subcommands:
#   open              — keybinding entry: create/switch to hub session
#   project-col       — fzf loop for col 1 (project picker)
#   session-col       — fzf loop for col 2 (sessions for selected project)
#   subtask-col       — fzf loop for col 3 (sub-tasks for selected session)
#   preview-col       — watch loop for col 4 (task context + terminal)
#   list-projects     — output project lines (for fzf reload)
#   list-sessions     — output session lines for a repo (for fzf reload)
#   list-subtasks     — output subtask lines for a session (for fzf reload)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"
source "$SCRIPT_DIR/status-agents.sh"

# ── Colors ──────────────────────────────────────────────────────────────

DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ── IPC files ───────────────────────────────────────────────────────────

IPC_DIR="/tmp/wta-dash"

ipc_file() { echo "${IPC_DIR}/$1"; }

ipc_read() {
    local f
    f=$(ipc_file "$1")
    [ -f "$f" ] && cat "$f" 2>/dev/null
}

ipc_write() {
    mkdir -p "$IPC_DIR"
    echo "$2" > "$(ipc_file "$1")"
}

# ── Shared helpers ──────────────────────────────────────────────────────

status_display_icon() {
    case "$1" in
        prompt) printf "${YELLOW}⏎${NC}" ;;
        active) printf "${GREEN}●${NC}" ;;
        dead)   printf "${RED}✗${NC}" ;;
        off)    printf "${DIM}◌${NC}" ;;
        *)      printf "${DIM}?${NC}" ;;
    esac
}

status_sort_key() {
    case "$1" in
        prompt) echo 0 ;; dead) echo 1 ;; active) echo 2 ;; off) echo 3 ;; *) echo 9 ;;
    esac
}

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

# ── Col 1: Projects ────────────────────────────────────────────────────

build_project_lines() {
    local search_dir="${PROJECTS:-$HOME/localGit}"

    # 1) Repos with metadata entries (above the line)
    local meta_repos=()
    if [ -f "$METADATA_FILE" ]; then
        while IFS= read -r repo; do
            [ -z "$repo" ] && continue
            meta_repos+=("$repo")
        done < <(jq -r '[.[].repo] | unique | .[]' "$METADATA_FILE" 2>/dev/null)
    fi

    # Count sessions per repo for display
    for repo in "${meta_repos[@]}"; do
        local count=0 cp=0 ca=0
        while IFS= read -r session; do
            [ -z "$session" ] && continue
            [[ "$session" == *-hub ]] && continue
            ((count++))
            local st
            st=$(agent_status_icon "$session")
            case "$st" in prompt) ((cp++)) ;; active) ((ca++)) ;; esac
        done < <(find_sessions_by_repo "$repo")

        local suffix=""
        [ $cp -gt 0 ] && suffix+=" ${YELLOW}⏎${cp}${NC}"
        [ $ca -gt 0 ] && suffix+=" ${GREEN}●${ca}${NC}"
        [ $count -gt 0 ] && [ $cp -eq 0 ] && [ $ca -eq 0 ] && suffix+=" ${DIM}${count}${NC}"

        local main_repo_path=""
        main_repo_path=$(jq -r --arg r "$repo" \
            '[.[] | select(.repo == $r) | .main_repo_path] | first // empty' \
            "$METADATA_FILE" 2>/dev/null)

        printf " %b%s%b\t%s\t%s\n" "${BOLD}" "$repo" "${NC}${suffix}" "$repo" "$main_repo_path"
    done

    # 2) Separator
    printf "${DIM}────────────────────${NC}\t\t\n"

    # 3) Repos from $PROJECTS not in metadata
    if [ -d "$search_dir" ]; then
        while IFS= read -r git_dir; do
            local repo_path="${git_dir%/.git}"
            local repo_name
            repo_name=$(basename "$repo_path")

            # Skip if already in metadata
            local skip=false
            for mr in "${meta_repos[@]}"; do
                [ "$mr" = "$repo_name" ] && skip=true && break
            done
            $skip && continue

            printf " ${DIM}%s${NC}\t%s\t%s\n" "$repo_name" "$repo_name" "$repo_path"
        done < <(find "$search_dir" -maxdepth 2 -type d -name .git 2>/dev/null | sort)
    fi
}

cmd_list_projects() {
    build_project_lines
}

cmd_project_col() {
    trap "rm -f '$(ipc_file project)' '$(ipc_file session)' '$(ipc_file subtask)'" EXIT

    while true; do
        local lines
        lines=$(build_project_lines)

        if [ -z "$lines" ]; then
            lines=$(printf "${DIM}  No projects found${NC}\t\t\n")
        fi

        local result
        result=$(echo -e "$lines" | fzf \
            --ansi \
            --no-sort \
            --layout=reverse \
            --no-info \
            --header-first \
            --header="Projects" \
            --prompt="" \
            --pointer="▸" \
            --delimiter=$'\t' \
            --with-nth=1 \
            --height=100% \
            --expect=enter,right \
            --bind "focus:execute-silent(echo {2} > '$(ipc_file project)'; echo {3} > '$(ipc_file project_path)')" \
            --bind "ctrl-r:reload(bash '$SCRIPT_DIR/dashboard.sh' list-projects)" \
        ) || true

        local key
        key=$(echo "$result" | head -1)

        if [ "$key" = "enter" ] || [ "$key" = "right" ]; then
            # Bootstrap hub for untracked projects
            local sel_repo sel_path
            sel_repo=$(ipc_read project)
            sel_path=$(ipc_read project_path)
            if [ -n "$sel_repo" ] && [ -n "$sel_path" ]; then
                local hub="${sel_repo}-hub"
                if ! session_in_metadata "$hub"; then
                    save_session "$hub" "$sel_repo" "hub" "" "" "$sel_path" false "Dashboard hub" "" "" ""
                fi
            fi
            # Move focus to col 2
            tmux select-pane -R 2>/dev/null || true
        fi

        [ -t 0 ] || break
        sleep 0.2
    done
}

# ── Col 2: Sessions ────────────────────────────────────────────────────

_build_session_lines_sorted() {
    local repo_name="$1"
    [ -z "$repo_name" ] && return

    local hub_name="${repo_name}-hub"
    local raw_lines=()

    while IFS= read -r session; do
        [ -z "$session" ] && continue
        [ "$session" = "$hub_name" ] && continue

        local parent
        parent=$(get_session_field "$session" "parent_session")
        # Show sessions that are top-level: parent is empty, or parent is the hub
        if [ -n "$parent" ] && [ "$parent" != "$hub_name" ]; then
            continue
        fi

        local status branch description
        status=$(agent_status_icon "$session")
        branch=$(get_session_field "$session" "branch")
        description=$(get_session_field "$session" "description")

        local sort_key
        sort_key=$(status_sort_key "$status")

        local s_icon
        s_icon=$(status_display_icon "$status")

        local label="${session#${repo_name}-}"
        [ ${#label} -gt 20 ] && label="${label:0:19}~"

        local desc_part=""
        if [ -n "$description" ]; then
            local short_desc="${description:0:25}"
            desc_part=" ${DIM}${short_desc}${NC}"
        fi

        raw_lines+=("$(printf "%s|%b %s%b\t%s\t%s" \
            "$sort_key" "$s_icon" "$label" "$desc_part" "$session" "$status")")
    done < <(find_sessions_by_repo "$repo_name")

    if [ ${#raw_lines[@]} -eq 0 ]; then
        printf "${DIM}  No sessions. ^N to create${NC}\t\t\n"
        return
    fi

    printf '%s\n' "${raw_lines[@]}" | sort -t'|' -k1,1n | sed 's/^[0-9]|//'
}

cmd_list_sessions() {
    _build_session_lines_sorted "$1"
}

cmd_session_col() {
    local initial_repo="$1"

    while true; do
        local repo_name
        repo_name=$(ipc_read project)
        [ -z "$repo_name" ] && repo_name="$initial_repo"

        local repo_path
        repo_path=$(ipc_read project_path)

        local lines
        lines=$(_build_session_lines_sorted "$repo_name")
        [ -z "$lines" ] && lines=$(printf "${DIM}  No sessions${NC}\t\t\n")

        local result
        result=$(echo -e "$lines" | fzf \
            --ansi \
            --no-sort \
            --layout=reverse \
            --no-info \
            --header-first \
            --header="Sessions" \
            --prompt="" \
            --pointer="▸" \
            --delimiter=$'\t' \
            --with-nth=1 \
            --height=100% \
            --expect=enter,right,left \
            --bind "focus:execute-silent(echo {2} > '$(ipc_file session)')" \
            --bind "ctrl-n:execute(tmux display-popup -E -w 85% -h 85% -d '${repo_path:-~}' '$SCRIPT_DIR/create-worktree.sh')+reload(bash '$SCRIPT_DIR/dashboard.sh' list-sessions \"\$(cat '$(ipc_file project)' 2>/dev/null)\")" \
            --bind "ctrl-t:execute(tmux display-popup -E -w 95% -h 95% -d '${repo_path:-~}' '$SCRIPT_DIR/task-selector.sh')+reload(bash '$SCRIPT_DIR/dashboard.sh' list-sessions \"\$(cat '$(ipc_file project)' 2>/dev/null)\")" \
            --bind "ctrl-d:execute(tmux display-popup -E -w 85% -h 85% '$SCRIPT_DIR/kill-worktree.sh' {2})+reload(bash '$SCRIPT_DIR/dashboard.sh' list-sessions \"\$(cat '$(ipc_file project)' 2>/dev/null)\")" \
            --bind "ctrl-r:reload(bash '$SCRIPT_DIR/dashboard.sh' list-sessions \"\$(cat '$(ipc_file project)' 2>/dev/null)\")" \
        ) || true

        local key
        key=$(echo "$result" | head -1)
        local selected_line
        selected_line=$(echo "$result" | tail -1)
        local selected_session
        selected_session=$(echo "$selected_line" | awk -F'\t' '{print $2}')

        case "$key" in
            enter)
                if [ -n "$selected_session" ]; then
                    tmux switch-client -t "$selected_session" 2>/dev/null || true
                fi
                ;;
            right)
                tmux select-pane -R 2>/dev/null || true
                ;;
            left)
                tmux select-pane -L 2>/dev/null || true
                ;;
        esac

        [ -t 0 ] || break
        sleep 0.2
    done
}

# ── Col 3: Sub-tasks ──────────────────────────────────────────────────

_build_subtask_lines_sorted() {
    local parent_session="$1"
    [ -z "$parent_session" ] && return

    local repo_name
    repo_name=$(get_session_field "$parent_session" "repo")
    [ -z "$repo_name" ] && return

    local raw_lines=()

    while IFS= read -r session; do
        [ -z "$session" ] && continue

        local parent
        parent=$(get_session_field "$session" "parent_session")
        # Only show sessions whose parent matches selected session
        [ "$parent" != "$parent_session" ] && continue

        local status description
        status=$(agent_status_icon "$session")
        description=$(get_session_field "$session" "description")

        local sort_key
        sort_key=$(status_sort_key "$status")

        local s_icon
        s_icon=$(status_display_icon "$status")

        local label="${session#${repo_name}-}"
        [ ${#label} -gt 20 ] && label="${label:0:19}~"

        local desc_part=""
        if [ -n "$description" ]; then
            local short_desc="${description:0:25}"
            desc_part=" ${DIM}${short_desc}${NC}"
        fi

        raw_lines+=("$(printf "%s|%b %s%b\t%s\t%s" \
            "$sort_key" "$s_icon" "$label" "$desc_part" "$session" "$status")")
    done < <(find_sessions_by_repo "$repo_name")

    if [ ${#raw_lines[@]} -eq 0 ]; then
        printf "${DIM}  No sub-tasks${NC}\t\t\n"
        return
    fi

    printf '%s\n' "${raw_lines[@]}" | sort -t'|' -k1,1n | sed 's/^[0-9]|//'
}

cmd_list_subtasks() {
    _build_subtask_lines_sorted "$1"
}

cmd_subtask_col() {
    while true; do
        local parent_session
        parent_session=$(ipc_read session)

        local lines
        lines=$(_build_subtask_lines_sorted "$parent_session")
        [ -z "$lines" ] && lines=$(printf "${DIM}  No sub-tasks${NC}\t\t\n")

        local result
        result=$(echo -e "$lines" | fzf \
            --ansi \
            --no-sort \
            --layout=reverse \
            --no-info \
            --header-first \
            --header="Sub-tasks" \
            --prompt="" \
            --pointer="▸" \
            --delimiter=$'\t' \
            --with-nth=1 \
            --height=100% \
            --expect=enter,right,left \
            --bind "focus:execute-silent(echo {2} > '$(ipc_file subtask)')" \
            --bind "ctrl-d:execute(tmux display-popup -E -w 85% -h 85% '$SCRIPT_DIR/kill-worktree.sh' {2})+reload(bash '$SCRIPT_DIR/dashboard.sh' list-subtasks \"\$(cat '$(ipc_file session)' 2>/dev/null)\")" \
            --bind "ctrl-r:reload(bash '$SCRIPT_DIR/dashboard.sh' list-subtasks \"\$(cat '$(ipc_file session)' 2>/dev/null)\")" \
        ) || true

        local key
        key=$(echo "$result" | head -1)
        local selected_line
        selected_line=$(echo "$result" | tail -1)
        local selected_session
        selected_session=$(echo "$selected_line" | awk -F'\t' '{print $2}')

        case "$key" in
            enter)
                if [ -n "$selected_session" ]; then
                    tmux switch-client -t "$selected_session" 2>/dev/null || true
                fi
                ;;
            right)
                tmux select-pane -R 2>/dev/null || true
                ;;
            left)
                tmux select-pane -L 2>/dev/null || true
                ;;
        esac

        [ -t 0 ] || break
        sleep 0.2
    done
}

# ── Col 4: Preview ─────────────────────────────────────────────────────

render_task_context() {
    local session="$1"
    local worktree_path
    worktree_path=$(get_session_field "$session" "worktree_path")

    # Try wt-*.md in worktree — show task block (after first ---)
    if [ -n "$worktree_path" ] && [ -d "$worktree_path" ]; then
        local task_file=""
        for f in "$worktree_path"/wt-*.md; do
            [ -f "$f" ] && task_file="$f" && break
        done

        if [ -n "$task_file" ]; then
            echo -e "${BOLD}── Task ──────────────────────────────${NC}"
            # Show task block: everything after first ---
            awk '/^---[[:space:]]*$/ { found=1; next } found { print }' "$task_file" | head -18
            return
        fi
    fi

    # Fallback: description from metadata
    local description
    description=$(get_session_field "$session" "description")
    if [ -n "$description" ]; then
        echo -e "${BOLD}── Context ───────────────────────────${NC}"
        echo "$description"
        return
    fi

    # Fallback: shared context
    if [ -n "$worktree_path" ]; then
        local shared_ctx
        shared_ctx="$(dirname "$worktree_path")/.shared/context.md"
        if [ -f "$shared_ctx" ]; then
            echo -e "${BOLD}── Project Context ───────────────────${NC}"
            head -15 "$shared_ctx"
            return
        fi
    fi
}

render_terminal_capture() {
    local session="$1"

    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo -e "${DIM}  Session not running${NC}"
        return
    fi

    local captured
    captured=$(tmux capture-pane -t "$session" -p 2>/dev/null | grep -v '^$' | tail -15)
    if [ -n "$captured" ]; then
        echo "$captured"
    else
        echo -e "${DIM}  (no output)${NC}"
    fi
}

render_session_header() {
    local session="$1"

    local status branch agent_cmd created
    status=$(agent_status_icon "$session")
    branch=$(get_session_field "$session" "branch")
    agent_cmd=$(get_session_field "$session" "agent_cmd")
    created=$(get_session_field "$session" "created_at")

    local status_label
    case "$status" in
        prompt) status_label="${YELLOW}⏎ needs input${NC}" ;;
        active) status_label="${GREEN}● working${NC}" ;;
        off)    status_label="${DIM}◌ idle${NC}" ;;
        dead)   status_label="${RED}✗ dead${NC}" ;;
    esac

    local time_ago
    time_ago=$(human_time_ago "$created")

    echo -e "${BOLD}${session}${NC}"
    echo -e "${DIM}${branch:-no branch}  ${agent_cmd:-no agent}  ${time_ago}${NC}  ${status_label}"
    echo ""
}

cmd_preview_col() {
    while true; do
        clear

        # Determine which session to preview: prefer subtask, then session
        local preview_session
        preview_session=$(ipc_read subtask)
        if [ -z "$preview_session" ] || [ "$preview_session" = "(none)" ]; then
            preview_session=$(ipc_read session)
        fi

        if [ -z "$preview_session" ] || [ "$preview_session" = "(none)" ]; then
            # Show project summary if available
            local repo_name
            repo_name=$(ipc_read project)
            if [ -n "$repo_name" ]; then
                echo -e "${BOLD}${repo_name}${NC}"
                echo -e "${DIM}───────────────────────────────────${NC}"
                echo ""
                echo -e "${DIM}Select a session to see details${NC}"
            else
                echo -e "${DIM}Select a project${NC}"
            fi
        else
            render_session_header "$preview_session"
            render_task_context "$preview_session"
            echo ""
            echo -e "${BOLD}── Terminal ──────────────────────────${NC}"
            render_terminal_capture "$preview_session"
        fi

        sleep 3
    done
}

# ── Subcommand: open ────────────────────────────────────────────────────

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

    # Try to resolve to git root (may fail if not in a repo — that's OK)
    local resolved
    resolved=$(cd "$repo_path" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || true

    local repo_name=""
    local hub_name=""

    if [ -n "$resolved" ]; then
        repo_path="$resolved"
        repo_name=$(get_repo_name "$repo_path")
        hub_name="${repo_name}-hub"

        # Pre-select this project in IPC so col 2 starts populated
        ipc_write project "$repo_name"
        ipc_write project_path "$repo_path"
    fi

    # If we have a hub, check toggle behavior
    if [ -n "$hub_name" ] && [ -n "${TMUX:-}" ]; then
        local current_session
        current_session=$(tmux display-message -p '#S' 2>/dev/null)
        if [ "$current_session" = "$hub_name" ]; then
            tmux switch-client -l 2>/dev/null || true
            return 0
        fi
    fi

    # Reuse existing hub session if alive
    if [ -n "$hub_name" ] && tmux has-session -t "$hub_name" 2>/dev/null; then
        if tmux list-windows -t "$hub_name" -F '#{window_name}' 2>/dev/null | grep -q '^dashboard$'; then
            if [ -z "${TMUX:-}" ]; then
                tmux attach-session -t "$hub_name"
            else
                tmux switch-client -t "$hub_name:dashboard"
            fi
            return 0
        fi

        setup_dashboard_window "$hub_name" "$repo_path" "$repo_name"
        if [ -z "${TMUX:-}" ]; then
            tmux attach-session -t "$hub_name"
        else
            tmux switch-client -t "$hub_name:dashboard"
        fi
        return 0
    fi

    # Create new hub session (use a generic name if no repo detected)
    if [ -z "$hub_name" ]; then
        hub_name="worktree-hub"
        repo_name=""
    fi

    tmux new-session -d -s "$hub_name" -c "${repo_path:-$HOME}"
    setup_dashboard_window "$hub_name" "${repo_path:-$HOME}" "$repo_name"

    # Register in metadata if we have a repo
    if [ -n "$repo_name" ]; then
        save_session "$hub_name" "$repo_name" "hub" "" "" "$repo_path" false "Dashboard hub" "" "" ""
    fi

    # Attach/switch
    if [ -z "${TMUX:-}" ]; then
        tmux attach-session -t "$hub_name"
    else
        tmux switch-client -t "$hub_name:dashboard"
    fi
}

# ── Setup 4-pane layout ────────────────────────────────────────────────

setup_dashboard_window() {
    local hub_name="$1"
    local repo_path="$2"
    local repo_name="$3"

    # Clean IPC from previous session
    rm -rf "$IPC_DIR"
    mkdir -p "$IPC_DIR"

    # Pre-populate IPC if we know the repo
    if [ -n "$repo_name" ]; then
        ipc_write project "$repo_name"
        ipc_write project_path "$repo_path"
    fi

    # Rename first window
    local first_window
    first_window=$(tmux list-windows -t "$hub_name" -F '#{window_id}' 2>/dev/null | head -1)
    if [ -n "$first_window" ]; then
        tmux rename-window -t "${hub_name}:${first_window}" "dashboard"
    fi

    # Build layout right-to-left using pane IDs to avoid index shifting.
    # Start: pane 0 = full width. We split it 3 times.

    # Pane 0 starts as the full window. Assign it to preview (rightmost).
    # Split left from it to create the other 3 panes.

    # Step 1: pane 0 = preview (will end up rightmost)
    local p0
    p0=$(tmux list-panes -t "${hub_name}:dashboard" -F '#{pane_id}' | head -1)

    # Step 2: split left of preview → subtask-col (55% left, 45% preview)
    local p_subtask
    p_subtask=$(tmux split-window -t "$p0" -hb -l 55% -P -F '#{pane_id}' \
        "bash '$SCRIPT_DIR/dashboard.sh' subtask-col")

    # Step 3: split left of subtask → session-col (65% left of subtask's portion)
    local p_session
    p_session=$(tmux split-window -t "$p_subtask" -hb -l 65% -P -F '#{pane_id}' \
        "bash '$SCRIPT_DIR/dashboard.sh' session-col '$repo_name'")

    # Step 4: split left of session → project-col (20% of session's portion ≈ 15% total)
    tmux split-window -t "$p_session" -hb -l 20% \
        "bash '$SCRIPT_DIR/dashboard.sh' project-col"

    # Pane 0 (the original) becomes preview
    tmux send-keys -t "$p0" "bash '$SCRIPT_DIR/dashboard.sh' preview-col" Enter

    # Focus leftmost pane (project column)
    tmux select-pane -t "${hub_name}:dashboard.0"
}

# ── Dispatch ────────────────────────────────────────────────────────────

case "${1:-open}" in
    open)           cmd_open "$2" ;;
    project-col)    cmd_project_col ;;
    session-col)    cmd_session_col "$2" ;;
    subtask-col)    cmd_subtask_col ;;
    preview-col)    cmd_preview_col ;;
    list-projects)  cmd_list_projects ;;
    list-sessions)  cmd_list_sessions "$2" ;;
    list-subtasks)  cmd_list_subtasks "$2" ;;
    *)              cmd_open "$2" ;;
esac
