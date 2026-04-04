#!/usr/bin/env bash

# wta — non-interactive CLI for orchestrator agents
#
# Designed to be called by AI agents (via bash) to drive the plugin.
# All commands are non-interactive: no fzf, no prompts, no /dev/tty reads.
#
# Usage: bash /path/to/wta.sh <command> [args...]
#
# Read-only:
#   status [repo]              — session topology + agent state
#   broadcasts <repo>          — list/read .shared/broadcasts/
#   capture <session>          — terminal output of a session
#   topology <task.md>         — task dependency graph with completion state
#   diff <session>             — git diff vs base branch
#
# Mutating:
#   spawn <task.md> <task-id>  — create worktree + session + start agent
#   send <session> <text>      — send text to an agent's pane
#   kill <session>             — full cleanup (worktree + metadata + branch)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"
source "$PLUGIN_DIR/lib/task-parser.sh"
source "$SCRIPT_DIR/status-agents.sh"

# ── status [repo] ─────────────────────────────────────────────────────

cmd_status() {
    local filter_repo="${1:-}"

    if [ ! -f "$METADATA_FILE" ]; then
        echo "No sessions."
        return 0
    fi

    local sessions
    if [ -n "$filter_repo" ]; then
        sessions=$(find_sessions_by_repo "$filter_repo")
    else
        sessions=$(list_sessions)
    fi

    if [ -z "$sessions" ]; then
        echo "No sessions${filter_repo:+ for repo '$filter_repo'}."
        return 0
    fi

    printf "%-30s %-10s %-24s %-8s %s\n" "SESSION" "STATUS" "BRANCH" "AGENT" "DESCRIPTION"
    printf "%-30s %-10s %-24s %-8s %s\n" "-------" "------" "------" "-----" "-----------"

    while IFS= read -r session; do
        [ -z "$session" ] && continue

        local status branch agent_cmd description
        status=$(agent_status_icon "$session")
        branch=$(get_session_field "$session" "branch")
        agent_cmd=$(get_session_field "$session" "agent_cmd")
        description=$(get_session_field "$session" "description")

        local agent_name="${agent_cmd%% *}"

        printf "%-30s %-10s %-24s %-8s %s\n" \
            "$session" "$status" "${branch:-—}" "${agent_name:-—}" "${description:0:40}"
    done <<< "$sessions"
}

# ── broadcasts <repo> ─────────────────────────────────────────────────

cmd_broadcasts() {
    local repo_name="${1:?Usage: wta broadcasts <repo>}"

    local base_path
    base_path=$(expand_tilde "${WORKTREE_PATH:-$HOME/.worktrees}")
    local shared_dir="$base_path/$repo_name/.shared"

    if [ ! -d "$shared_dir/broadcasts" ]; then
        echo "No broadcasts directory for repo '$repo_name'."
        return 0
    fi

    local found=false
    for f in "$shared_dir/broadcasts"/*.md; do
        [ -f "$f" ] || continue
        found=true
        echo "=== $(basename "$f" .md) ==="
        cat "$f"
        echo ""
    done

    if [ "$found" = false ]; then
        echo "No broadcasts yet for repo '$repo_name'."
    fi
}

# ── capture <session> ─────────────────────────────────────────────────

cmd_capture() {
    local session_name="${1:?Usage: wta capture <session>}"

    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        echo "Session '$session_name' is not running."
        return 1
    fi

    tmux capture-pane -t "$session_name" -p 2>/dev/null | grep -v '^$' | tail -40
}

# ── topology <task.md> ────────────────────────────────────────────────

cmd_topology() {
    local task_file="${1:?Usage: wta topology <task.md>}"

    if [ ! -f "$task_file" ]; then
        echo "File not found: $task_file"
        return 1
    fi

    # Get repo context for checking session/merge state
    local repo_path repo_name
    repo_path=$(cd "$(dirname "$task_file")" && git rev-parse --show-toplevel 2>/dev/null) || true
    repo_name=""
    [ -n "$repo_path" ] && repo_name=$(get_repo_name "$repo_path")

    printf "%-20s %-6s %-8s %-40s %-20s %s\n" "TASK-ID" "PRI" "STATE" "TITLE" "DEPENDS" "BLOCKS"
    printf "%-20s %-6s %-8s %-40s %-20s %s\n" "-------" "---" "-----" "-----" "-------" "------"

    while IFS=$'\t' read -r tid title task_status priority depends blocks start_line end_line; do
        [ -z "$tid" ] && continue

        # Determine state
        local state="pending"
        if echo "$task_status" | grep -q '\[x\]'; then
            state="done"
        fi

        # Check if session exists
        if [ -n "$repo_name" ]; then
            local sanitized
            sanitized=$(echo "$tid" | tr '/' '-' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            local session_name="${repo_name}-${sanitized}"
            local branch_name="wt/${sanitized}"

            if tmux has-session -t "$session_name" 2>/dev/null; then
                local agent_state
                agent_state=$(agent_status_icon "$session_name")
                state="$agent_state"
            elif [ -f "$METADATA_FILE" ] && jq -e --arg s "$session_name" '.[$s]' "$METADATA_FILE" >/dev/null 2>&1; then
                state="dead"
            fi

            # Check if merged
            if [ "$state" != "done" ] && [ -n "$repo_path" ]; then
                local base_branch=""
                [ -f "$METADATA_FILE" ] && base_branch=$(jq -r --arg s "$session_name" '.[$s].parent_branch // empty' "$METADATA_FILE" 2>/dev/null)
                [ -z "$base_branch" ] && base_branch=$(get_default_branch "$repo_path")
                if git -C "$repo_path" branch --merged "$base_branch" 2>/dev/null | sed 's/^[*+ ] //' | grep -qx "$branch_name"; then
                    state="merged"
                fi
            fi
        fi

        local dep_str="${depends:-—}"
        local blk_str="${blocks:-—}"
        [ "$dep_str" = "None" ] || [ "$dep_str" = "none" ] && dep_str="—"
        [ "$blk_str" = "None" ] || [ "$blk_str" = "none" ] && blk_str="—"

        printf "%-20s %-6s %-8s %-40s %-20s %s\n" \
            "$tid" "${priority:-—}" "$state" "${title:0:40}" "${dep_str:0:20}" "${blk_str:0:20}"
    done < <(parse_tasks "$task_file")
}

# ── diff <session> ────────────────────────────────────────────────────

cmd_diff() {
    local session_name="${1:?Usage: wta diff <session>}"

    if ! session_in_metadata "$session_name"; then
        echo "Session '$session_name' not found in metadata."
        return 1
    fi

    local branch main_repo_path parent_branch
    branch=$(get_session_field "$session_name" "branch")
    main_repo_path=$(get_session_field "$session_name" "main_repo_path")
    parent_branch=$(get_session_field "$session_name" "parent_branch")

    if [ -z "$parent_branch" ]; then
        parent_branch=$(get_default_branch "$main_repo_path")
    fi

    if [ -z "$branch" ] || [ -z "$main_repo_path" ]; then
        echo "Missing branch or repo path in metadata."
        return 1
    fi

    echo "# Diff: $branch vs $parent_branch"
    echo ""
    git -C "$main_repo_path" diff "${parent_branch}...${branch}" 2>/dev/null || \
        echo "Could not compute diff (branch may not exist yet)."
}

# ── spawn <task.md> <task-id> ─────────────────────────────────────────

cmd_spawn() {
    local task_file="${1:?Usage: wta spawn <task.md> <task-id>}"
    local target_tid="${2:?Usage: wta spawn <task.md> <task-id>}"

    if [ ! -f "$task_file" ]; then
        echo "File not found: $task_file"
        return 1
    fi

    # Validate task file
    if ! validate_task_file "$task_file"; then
        return 1
    fi

    # Find the task in the file
    local found_tid="" found_title="" found_start="" found_end=""
    while IFS=$'\t' read -r tid title task_status priority depends blocks start_line end_line; do
        if [ "$tid" = "$target_tid" ]; then
            found_tid="$tid"
            found_title="$title"
            found_start="$start_line"
            found_end="$end_line"
            break
        fi
    done < <(parse_tasks "$task_file")

    if [ -z "$found_tid" ]; then
        echo "Task '$target_tid' not found in $task_file"
        echo ""
        echo "Available tasks:"
        parse_tasks "$task_file" | awk -F'\t' '{ print "  " $1 " — " $2 }'
        return 1
    fi

    # Resolve repo
    local repo_path repo_name
    repo_path=$(cd "$(dirname "$task_file")" && git rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$repo_path" ]; then
        echo "Not in a git repository."
        return 1
    fi
    repo_name=$(get_repo_name "$repo_path")

    # Sanitize for branch/session naming
    local sanitized
    sanitized=$(sanitize_name "$found_tid")
    local branch_name="wt/${sanitized}"
    local topic="${sanitized}"
    local session_name
    session_name=$(generate_session_name "$repo_name" "$topic")
    local worktree_path
    worktree_path=$(get_worktree_path "$repo_name" "$sanitized")

    # Check for existing session
    if session_exists "$session_name"; then
        echo "Session '$session_name' already exists."
        echo "Status: $(agent_status_icon "$session_name")"
        return 1
    fi

    # Create worktree (exit 0=created, 1=error, 2=already exists)
    local wt_result=0
    create_worktree_for_branch "$repo_path" "$worktree_path" "$branch_name" "true" || wt_result=$?
    if [ "$wt_result" -eq 1 ]; then
        echo "Failed to create worktree."
        return 1
    elif [ "$wt_result" -eq 2 ]; then
        echo "Reusing existing worktree at $worktree_path"
    fi

    # Seed shared context from preamble (first spawn only)
    local shared_dir
    shared_dir="$(dirname "$worktree_path")/.shared"
    if [ ! -f "$shared_dir/context.md" ]; then
        extract_preamble "$task_file" > "$shared_dir/context.md"
        echo "Seeded .shared/context.md from preamble."
    fi

    # Copy preamble + task block into the worktree
    local branch_filename
    branch_filename=$(echo "$branch_name" | tr '/' '-')
    local task_output="$worktree_path/${branch_filename}.md"
    {
        extract_preamble "$task_file"
        echo ""
        echo "---"
        echo ""
        extract_task_block "$task_file" "$found_start" "$found_end"
    } > "$task_output"

    # Resolve parent session (the orchestrator calling us)
    local parent_session=""
    parent_session=$(get_current_session 2>/dev/null || true)

    # Spawn session with auto agent (no interactive prompt)
    local agent_cmd="${WORKTREE_AGENT_CMD:-claude}"
    local launch_agent=false
    if command_exists "${agent_cmd%% *}"; then
        launch_agent=true
    fi

    # Create tmux session (no switch)
    create_tmux_session "$session_name" "$worktree_path" "$launch_agent" "$agent_cmd" "$topic" "$branch_name"

    # Auto-detect parent branch
    local parent_branch=""
    parent_branch=$(cd "$repo_path" && git rev-parse --abbrev-ref HEAD 2>/dev/null)

    # Save metadata
    save_session "$session_name" "$repo_name" "$topic" "$branch_name" \
        "$worktree_path" "$repo_path" "$launch_agent" "$found_title" "$agent_cmd" \
        "$parent_branch" "$parent_session"

    # Write agent config
    write_agent_config "$worktree_path" "$agent_cmd" "$found_tid" "$branch_filename"

    echo "Spawned: $session_name"
    echo "  Branch:    $branch_name"
    echo "  Worktree:  $worktree_path"
    echo "  Agent:     ${agent_cmd} ($([ "$launch_agent" = true ] && echo 'started' || echo 'not found'))"
    echo "  Task:      $found_tid — $found_title"
}

# ── send <session> <text> ─────────────────────────────────────────────

cmd_send() {
    local session_name="${1:?Usage: wta send <session> <text>}"
    shift
    local text="${*:?Usage: wta send <session> <text>}"

    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        echo "Session '$session_name' is not running."
        return 1
    fi

    local tmpfile
    tmpfile=$(mktemp)
    printf '%s' "$text" > "$tmpfile"

    tmux load-buffer "$tmpfile"
    tmux paste-buffer -t "$session_name"
    tmux send-keys -t "$session_name" C-m

    rm -f "$tmpfile"
    echo "Sent to $session_name."
}

# ── kill <session> ────────────────────────────────────────────────────

cmd_kill() {
    local session_name="${1:?Usage: wta kill <session>}"

    if ! session_in_metadata "$session_name"; then
        # Just kill tmux session if it exists
        if tmux has-session -t "$session_name" 2>/dev/null; then
            tmux kill-session -t "$session_name"
            echo "Killed tmux session '$session_name' (no metadata)."
        else
            echo "Session '$session_name' not found."
        fi
        return 0
    fi

    local worktree_path main_repo_path branch
    worktree_path=$(get_session_field "$session_name" "worktree_path")
    main_repo_path=$(get_session_field "$session_name" "main_repo_path")
    branch=$(get_session_field "$session_name" "branch")

    # Kill tmux session
    if tmux has-session -t "$session_name" 2>/dev/null; then
        tmux kill-session -t "$session_name" 2>/dev/null || true
        echo "Killed tmux session."
    fi

    # Remove worktree (skip if it's the main repo)
    if [ -d "$worktree_path" ] && [ "$worktree_path" != "$main_repo_path" ]; then
        if [ -d "$main_repo_path" ]; then
            (cd "$main_repo_path" && git worktree remove --force "$worktree_path" 2>/dev/null) || rm -rf "$worktree_path"
        else
            rm -rf "$worktree_path"
        fi
        echo "Removed worktree."
    fi

    # Clean .shared if last session for this repo
    local repo
    repo=$(get_session_field "$session_name" "repo")
    if [ -n "$repo" ]; then
        local remaining
        remaining=$(find_sessions_by_repo "$repo" | grep -Fxcv "$session_name" 2>/dev/null || echo "0")
        if [ "$remaining" -eq 0 ]; then
            local shared_dir
            shared_dir="$(dirname "$worktree_path")/.shared"
            [ -d "$shared_dir" ] && rm -rf "$shared_dir" && echo "Cleaned .shared/ (last session)."
        fi
    fi

    # Delete wt/ branch
    if [ -n "$branch" ] && [[ "$branch" == wt/* ]] && [ -d "$main_repo_path" ]; then
        (cd "$main_repo_path" && git branch -d "$branch" 2>/dev/null) || \
        (cd "$main_repo_path" && git branch -D "$branch" 2>/dev/null) || true
        echo "Deleted branch $branch."
    fi

    # Delete metadata
    delete_session "$session_name"
    echo "Cleaned metadata."
    echo "Done: $session_name removed."
}

# ── Dispatch ──────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
wta — non-interactive CLI for orchestrator agents

Read-only:
  status [repo]              Session topology + agent state
  broadcasts <repo>          Read .shared/broadcasts/
  capture <session>          Terminal output of a session (last 40 lines)
  topology <task.md>         Task dependency graph with completion state
  diff <session>             Git diff vs base branch

Mutating:
  spawn <task.md> <task-id>  Create worktree + session + start agent
  send <session> <text>      Send text to an agent's terminal
  kill <session>             Full cleanup (session + worktree + metadata + branch)
EOF
}

command="${1:-}"
shift 2>/dev/null || true

case "$command" in
    status)     cmd_status "$@" ;;
    broadcasts) cmd_broadcasts "$@" ;;
    capture)    cmd_capture "$@" ;;
    topology)   cmd_topology "$@" ;;
    diff)       cmd_diff "$@" ;;
    spawn)      cmd_spawn "$@" ;;
    send)       cmd_send "$@" ;;
    kill)       cmd_kill "$@" ;;
    help|--help|-h|"")
        usage
        ;;
    *)
        echo "Unknown command: $command"
        echo ""
        usage
        exit 1
        ;;
esac
