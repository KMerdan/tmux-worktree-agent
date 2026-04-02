#!/usr/bin/env bash

# Persistent task sidebar for tmux-worktree-agent
# Shows task.md progress in a narrow fzf pane with interactive actions
#
# Lifecycle:
#   - Sidebar created  → sets sidebar_task_file in host session's metadata
#   - Sidebar pane dies → trap clears sidebar_task_file from metadata
#   - Host session killed (prefix+K) → entire metadata entry deleted (field goes with it)
#   - prefix+S in task session → looks up repo in metadata → finds sidebar host → jumps back
#
# Subcommands:
#   toggle       — keybinding entry: create sidebar / focus / unfocus / jump back
#   fzf-loop     — runs inside the sidebar pane (persistent fzf)
#   list         — output task lines (called by fzf reload)
#   kill-task    — remove a task's session+worktree (called by fzf ctrl-d)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"
source "$PLUGIN_DIR/lib/task-parser.sh"

SIDEBAR_TITLE="@task-sidebar"
SIDEBAR_WIDTH=30

# ── Build display lines for the narrow fzf ──────────────────────────
# Each line: <visible_text>\t<task_id>\t<status>\t<start>\t<end>
# fzf shows only the first tab-field via --with-nth=1
build_sidebar_lines() {
    local task_file="$1"
    local repo_name="$2"
    local repo_path="$3"

    local GRN='\033[0;32m'
    local DIM='\033[2m'
    local NC='\033[0m'

    local active_lines=()
    local pending_lines=()
    local done_lines=()

    while IFS=$'\t' read -r tid title task_status priority depends blocks start_line end_line; do
        [ -z "$tid" ] && continue

        local sanitized
        sanitized=$(echo "$tid" | tr '/' '-' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        local session_name="${repo_name}-${sanitized}"
        local branch_name="wt/${sanitized}"

        # Determine status
        local status="pending"
        local icon="${DIM}○${NC}"

        # Active session?
        if [ -f "$METADATA_FILE" ] && \
           jq -e --arg s "$session_name" '.[$s]' "$METADATA_FILE" >/dev/null 2>&1 && \
           tmux has-session -t "$session_name" 2>/dev/null; then
            status="active"
            icon="${GRN}●${NC}"
        else
            # Done? (merged or [x] in markdown)
            local is_done=false
            if echo "$task_status" | grep -q '\[x\]'; then
                is_done=true
            elif [ -d "$repo_path" ]; then
                # Prefer parent_branch from metadata, fall back to repo default
                local base_branch=""
                if [ -f "$METADATA_FILE" ]; then
                    base_branch=$(jq -r --arg s "$session_name" '.[$s].parent_branch // empty' "$METADATA_FILE" 2>/dev/null)
                fi
                if [ -z "$base_branch" ]; then
                    base_branch=$(get_default_branch "$repo_path")
                fi
                if git -C "$repo_path" branch --merged "$base_branch" 2>/dev/null \
                    | sed 's/^[*+ ] //' | grep -qx "$branch_name"; then
                    is_done=true
                elif git -C "$repo_path" log --merges --oneline "$base_branch" 2>/dev/null \
                    | grep -q "Merge branch '${branch_name}'"; then
                    is_done=true
                fi
            fi
            if [ "$is_done" = true ]; then
                status="done"
                icon="${GRN}✓${NC}"
            fi
        fi

        # Truncate title to fit the narrow pane
        local max_title=$((SIDEBAR_WIDTH - 14))
        local short_title="$title"
        if [ ${#short_title} -gt "$max_title" ]; then
            short_title="${short_title:0:$((max_title - 1))}~"
        fi

        local short_id="$tid"
        if [ ${#short_id} -gt 10 ]; then
            short_id="${short_id:0:9}~"
        fi

        local formatted_line
        formatted_line=$(printf "%b %-10s %s\t%s\t%s\t%s\t%s" \
            "$icon" "$short_id" "$short_title" \
            "$tid" "$status" "$start_line" "$end_line")

        case "$status" in
            active)  active_lines+=("$formatted_line") ;;
            done)    done_lines+=("$formatted_line") ;;
            *)       pending_lines+=("$formatted_line") ;;
        esac
    done < <(parse_tasks "$task_file")

    # Output: active → pending → done, with separators between groups
    for l in "${active_lines[@]}"; do
        echo "$l"
    done
    if [ ${#pending_lines[@]} -gt 0 ] && [ ${#active_lines[@]} -gt 0 ]; then
        printf "${DIM}────── pending ───────${NC}\t\t\t\t\n"
    fi
    for l in "${pending_lines[@]}"; do
        echo "$l"
    done
    if [ ${#done_lines[@]} -gt 0 ] && [ $((${#active_lines[@]} + ${#pending_lines[@]})) -gt 0 ]; then
        printf "${DIM}──────── done ────────${NC}\t\t\t\t\n"
    fi
    for l in "${done_lines[@]}"; do
        echo "$l"
    done
}

# Count done/total from task list
count_tasks() {
    local task_file="$1"
    local repo_name="$2"
    local repo_path="$3"

    local done=0 total=0

    while IFS=$'\t' read -r tid _title task_status _p _d _b _s _e; do
        [ -z "$tid" ] && continue
        total=$((total + 1))

        local sanitized
        sanitized=$(echo "$tid" | tr '/' '-' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        local branch_name="wt/${sanitized}"

        if echo "$task_status" | grep -q '\[x\]'; then
            done=$((done + 1))
        elif [ -d "$repo_path" ]; then
            local session_name="${repo_name}-${sanitized}"
            local base_branch=""
            if [ -f "$METADATA_FILE" ]; then
                base_branch=$(jq -r --arg s "$session_name" '.[$s].parent_branch // empty' "$METADATA_FILE" 2>/dev/null)
            fi
            if [ -z "$base_branch" ]; then
                base_branch=$(get_default_branch "$repo_path")
            fi
            if git -C "$repo_path" branch --merged "$base_branch" 2>/dev/null \
                | sed 's/^[*+ ] //' | grep -qx "$branch_name"; then
                done=$((done + 1))
            elif git -C "$repo_path" log --merges --oneline "$base_branch" 2>/dev/null \
                | grep -q "Merge branch '${branch_name}'"; then
                done=$((done + 1))
            fi
        fi
    done < <(parse_tasks "$task_file")

    echo "${done}/${total}"
}

# ── Spawn a single task ─────────────────────────────────────────────
spawn_single_task() {
    local task_file="$1"
    local task_id="$2"
    local start_line="$3"
    local end_line="$4"
    local repo_path="$5"
    local repo_name="$6"

    local sanitized_id
    sanitized_id=$(sanitize_name "$task_id")
    local branch_name="wt/${sanitized_id}"
    local topic="${sanitized_id}"
    local session_name
    session_name=$(generate_session_name "$repo_name" "$topic")
    local worktree_path
    worktree_path=$(get_worktree_path "$repo_name" "$sanitized_id")

    if session_exists "$session_name"; then
        return 0
    fi

    create_worktree_for_branch "$repo_path" "$worktree_path" "$branch_name" "true"
    local wt_result=$?
    [ "$wt_result" -eq 1 ] && return 1

    # Seed shared context
    local shared_dir
    shared_dir="$(dirname "$worktree_path")/.shared"
    if [ ! -f "$shared_dir/context.md" ]; then
        extract_preamble "$task_file" > "$shared_dir/context.md"
    fi

    # Copy task block into worktree
    local branch_filename
    branch_filename=$(echo "$branch_name" | tr '/' '-')
    {
        extract_preamble "$task_file"
        echo ""
        echo "---"
        echo ""
        extract_task_block "$task_file" "$start_line" "$end_line"
    } > "$worktree_path/${branch_filename}.md"

    # Spawn session (no auto-switch — we handle switching ourselves)
    # Resolve parent: prefer hub session, fall back to current session
    local parent_session="${repo_name}-hub"
    if ! session_in_metadata "$parent_session"; then
        parent_session=$(get_current_session 2>/dev/null || true)
    fi
    spawn_session_for_worktree "$session_name" "$repo_name" "$topic" \
        "$branch_name" "$worktree_path" "$repo_path" "" "false" "" "$parent_session"
    [ $? -ne 0 ] && return 1

    # Write agent config
    local agent_cmd_used
    agent_cmd_used=$(get_session_field "$session_name" "agent_cmd" 2>/dev/null)
    if [ -n "$agent_cmd_used" ]; then
        write_agent_config "$worktree_path" "$agent_cmd_used" "$task_id" "$branch_filename"
    fi
}

# ── Kill a task's session + worktree (no interactive confirmation) ──
cmd_kill_task() {
    local task_id="$1"
    local repo_name="$2"

    local sanitized_id
    sanitized_id=$(sanitize_name "$task_id")
    local session_name
    session_name=$(generate_session_name "$repo_name" "$sanitized_id")

    session_in_metadata "$session_name" || return 0

    local worktree_path main_repo_path branch
    worktree_path=$(get_session_field "$session_name" "worktree_path")
    main_repo_path=$(get_session_field "$session_name" "main_repo_path")
    branch=$(get_session_field "$session_name" "branch")

    tmux kill-session -t "$session_name" 2>/dev/null || true

    if [ -d "$worktree_path" ] && [ -d "$main_repo_path" ]; then
        git -C "$main_repo_path" worktree remove "$worktree_path" --force 2>/dev/null || \
            rm -rf "$worktree_path" 2>/dev/null || true
    fi

    if [ -n "$branch" ] && [[ "$branch" == wt/* ]] && [ -d "$main_repo_path" ]; then
        git -C "$main_repo_path" branch -D "$branch" 2>/dev/null || true
    fi

    delete_session "$session_name"
}

# ── Switch to a task session from the sidebar ──────────────────────
sidebar_switch_session() {
    local session_name="$1"

    if ! session_exists "$session_name"; then
        return 1
    fi

    local client_tty
    client_tty=$(tmux display-message -p '#{client_tty}' 2>/dev/null)

    if [ -n "$client_tty" ]; then
        tmux switch-client -t "$session_name" -c "$client_tty"
    else
        tmux switch-client -t "$session_name"
    fi
}

# ── Handle Enter on a selected task ────────────────────────────────
handle_enter() {
    local selected_line="$1"
    local task_file="$2"
    local repo_path="$3"
    local repo_name="$4"

    [ -z "$selected_line" ] && return

    local full_task_id status start_line end_line
    IFS=$'\t' read -r _display full_task_id status start_line end_line <<< "$selected_line"

    local sanitized_id
    sanitized_id=$(sanitize_name "$full_task_id")
    local session_name
    session_name=$(generate_session_name "$repo_name" "$sanitized_id")

    case "$status" in
        pending)
            spawn_single_task "$task_file" "$full_task_id" \
                "$start_line" "$end_line" "$repo_path" "$repo_name"
            sidebar_switch_session "$session_name"
            ;;
        active)
            sidebar_switch_session "$session_name"
            ;;
        done)
            sidebar_switch_session "$session_name"
            ;;
    esac
}

# ── Persistent fzf loop (runs inside the sidebar pane) ─────────────
cmd_fzf_loop() {
    local repo_path="$1"
    local task_file="$2"
    local host_session="$3"
    local repo_name
    repo_name=$(get_repo_name "$repo_path")

    # Clean up sidebar_task_file when this pane exits (crash, exit, pane killed)
    trap 'clear_sidebar_task_file "$host_session" 2>/dev/null' EXIT

    while true; do
        local lines
        lines=$(build_sidebar_lines "$task_file" "$repo_name" "$repo_path")

        if [ -z "$lines" ]; then
            echo "No tasks in $(basename "$task_file")"
            sleep 3
            continue
        fi

        local counts
        counts=$(count_tasks "$task_file" "$repo_name" "$repo_path")

        local fzf_output
        fzf_output=$(echo -e "$lines" | fzf \
            --ansi \
            --no-preview \
            --layout=reverse \
            --no-info \
            --no-separator \
            --header="Tasks $counts" \
            --header-first \
            --prompt="" \
            --pointer="▸" \
            --delimiter=$'\t' \
            --with-nth=1 \
            --height=100% \
            --bind "esc:execute-silent(tmux select-pane -l)+abort" \
            --bind "ctrl-d:execute-silent(bash '$SCRIPT_DIR/task-sidebar.sh' kill-task {2} '$repo_name')+reload(bash '$SCRIPT_DIR/task-sidebar.sh' list '$repo_path' '$task_file' '$repo_name')" \
            --bind "ctrl-r:reload(bash '$SCRIPT_DIR/task-sidebar.sh' list '$repo_path' '$task_file' '$repo_name')" \
            --expect=enter \
            2>/dev/null) || {
            # Esc or pane killed — if stdin still open, re-loop (Esc case)
            [ -t 0 ] && continue
            exit 0
        }

        local key selected_line
        key=$(echo "$fzf_output" | head -1)
        selected_line=$(echo "$fzf_output" | sed -n '2p')

        if [ "$key" = "enter" ] && [ -n "$selected_line" ]; then
            handle_enter "$selected_line" "$task_file" "$repo_path" "$repo_name"
        fi
    done
}

# ── Subcommand: list (called by fzf reload) ────────────────────────
cmd_list() {
    build_sidebar_lines "$1" "$3" "$2" 2>/dev/null
}

# ── Check if a session has a live sidebar pane ─────────────────────
session_has_sidebar_pane() {
    local session_name="$1"
    tmux list-panes -t "$session_name" -F '#{pane_title}' 2>/dev/null \
        | grep -q "$SIDEBAR_TITLE"
}

# ── Toggle sidebar (called by keybinding via run-shell) ────────────
cmd_toggle() {
    local current_session
    current_session=$(tmux display-message -p '#S' 2>/dev/null)

    # 1) This session has a sidebar pane → toggle focus within the session
    local sidebar_info
    sidebar_info=$(tmux list-panes -F '#{pane_id}:#{pane_title}:#{pane_active}' 2>/dev/null \
        | grep "$SIDEBAR_TITLE" | head -1)

    if [ -n "$sidebar_info" ]; then
        local pane_id pane_active
        pane_id=$(echo "$sidebar_info" | cut -d: -f1)
        pane_active=$(echo "$sidebar_info" | cut -d: -f3)

        if [ "$pane_active" = "1" ]; then
            tmux select-pane -l
        else
            tmux select-pane -t "$pane_id"
        fi
        return 0
    fi

    # 2) This session is in metadata → it might be a task session.
    #    Look up its repo and find the sidebar host for that repo.
    if session_in_metadata "$current_session"; then
        local repo
        repo=$(get_session_field "$current_session" "repo")

        if [ -n "$repo" ]; then
            local sidebar_host
            sidebar_host=$(find_sidebar_session_for_repo "$repo")

            # Don't jump to ourselves
            if [ -n "$sidebar_host" ] && [ "$sidebar_host" != "$current_session" ]; then
                # Validate the host session is alive and actually has a sidebar pane
                if session_exists "$sidebar_host" && session_has_sidebar_pane "$sidebar_host"; then
                    tmux switch-client -t "$sidebar_host"
                    return 0
                else
                    # Stale — clean it up
                    clear_sidebar_task_file "$sidebar_host" 2>/dev/null
                fi
            fi
        fi

        # Fall through to step 3 — this managed session can host its own sidebar
    fi

    # 3) Create sidebar if task.md exists in the repo

    local main_pane_path
    main_pane_path=$(tmux display-message -p '#{pane_current_path}')

    local repo_path
    repo_path=$(cd "$main_pane_path" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$repo_path" ]; then
        tmux display-message "Not in a git repository"
        return 1
    fi

    local task_file=""
    for name in task.md tasks.md TASK.md TASKS.md; do
        if [ -f "$repo_path/$name" ]; then
            task_file="$repo_path/$name"
            break
        fi
    done

    if [ -z "$task_file" ]; then
        tmux display-message "No task.md found in repo root"
        return 1
    fi

    if ! validate_task_file "$task_file" >/dev/null 2>&1; then
        tmux display-message "Invalid task file format"
        return 1
    fi

    # Register this session as the sidebar host in metadata
    set_sidebar_task_file "$current_session" "$task_file"

    local main_pane_id
    main_pane_id=$(tmux display-message -p '#{pane_id}')

    # Open narrow right split running the fzf loop
    # Pass host session name so the trap can clear the field on exit
    tmux split-window -h -l "$SIDEBAR_WIDTH" -t "$main_pane_id" \
        "bash '${SCRIPT_DIR}/task-sidebar.sh' fzf-loop '${repo_path}' '${task_file}' '${current_session}'"

    # Tag the new pane so we can find it later
    tmux select-pane -T "$SIDEBAR_TITLE"

    # Return focus to the main pane
    tmux select-pane -t "$main_pane_id"
}

# ── Dispatch ───────────────────────────────────────────────────────
case "${1:-toggle}" in
    toggle)     cmd_toggle ;;
    fzf-loop)   cmd_fzf_loop "$2" "$3" "$4" ;;
    list)       cmd_list "$2" "$3" "$4" ;;
    kill-task)  cmd_kill_task "$2" "$3" ;;
    *)          cmd_toggle ;;
esac
