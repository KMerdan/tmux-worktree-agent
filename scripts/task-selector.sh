#!/usr/bin/env bash

# Task Selector for tmux-worktree-agent
# Browses markdown files, parses tasks, multi-selects, and batch-spawns worktree sessions

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"
source "$PLUGIN_DIR/lib/task-parser.sh"

# Brief pause on error so user can read messages before popup closes
trap 'rc=$?; if [ $rc -ne 0 ]; then sleep 1.5; fi; exit $rc' EXIT

# Check dependencies
if ! check_dependencies; then
    exit 1
fi

# Browse markdown files in the repo using fzf
browse_markdown_files() {
    local root="$1"

    local find_cmd
    if command_exists fd; then
        find_cmd="fd --type f --extension md . '$root' --exclude .git --exclude node_modules"
    else
        find_cmd="find '$root' -type f -name '*.md' -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | sort"
    fi

    # Build preview command
    local preview_cmd
    if command_exists bat; then
        preview_cmd="bat --style=numbers --color=always \"${root}/{}\""
    else
        preview_cmd="cat \"${root}/{}\""
    fi

    local selected
    selected=$(eval "$find_cmd" | \
        sed "s|^$root/||" | \
        fzf \
            --ansi \
            --header="Select a task file (.md) | Enter: select | Esc: cancel" \
            --layout=reverse \
            --preview="$preview_cmd" \
            --preview-window=right:60%:wrap \
            --bind='esc:cancel')

    if [ -z "$selected" ]; then
        return 1
    fi

    echo "$root/$selected"
}


# Build topology-style display lines for fzf
# Each line: icon tid [priority] title (deps) │ start:end
build_topology_lines() {
    local task_file="$1"
    local repo_name="$2"
    local metadata_file="$3"
    local repo_path="$4"

    local GREEN='\033[0;32m'
    local YELLOW='\033[1;33m'
    local RED='\033[0;31m'
    local DIM='\033[2m'
    local NC='\033[0m'

    while IFS=$'\t' read -r tid title task_status priority depends blocks start_line end_line; do
        [ -z "$tid" ] && continue

        # Determine spawn status
        local sanitized
        sanitized=$(echo "$tid" | tr '/' '-' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        local session_name="${repo_name}-${sanitized}"
        local branch_name="wt/${sanitized}"

        # Pre-check metadata and session state
        local has_metadata=false
        if [ -f "$metadata_file" ] && jq -e --arg s "$session_name" '.[$s]' "$metadata_file" >/dev/null 2>&1; then
            has_metadata=true
        fi

        local has_session=false
        if [ "$has_metadata" = true ] && tmux has-session -t "$session_name" 2>/dev/null; then
            has_session=true
        fi

        # Check if branch has been merged into base branch (existing or deleted)
        local is_merged=false
        if [ -n "$repo_path" ]; then
            local base_branch
            base_branch=$(get_default_branch "$repo_path")
            if git -C "$repo_path" branch --merged "$base_branch" 2>/dev/null | sed 's/^[*+ ] //' | grep -qx "$branch_name"; then
                is_merged=true
            elif git -C "$repo_path" log --merges --oneline "$base_branch" 2>/dev/null | grep -q "Merge branch '${branch_name}'"; then
                is_merged=true
            fi
        fi

        # Priority: active session > merged > markdown [x] > dead session > pending
        local icon
        if [ "$has_session" = true ]; then
            icon="${GREEN}●${NC}"
        elif [ "$is_merged" = true ]; then
            icon="${GREEN}✓${NC}"
        elif echo "$task_status" | grep -q '\[x\]'; then
            icon="${GREEN}✓${NC}"
        elif [ "$has_metadata" = true ]; then
            icon="${RED}✗${NC}"
        else
            icon="${DIM}○${NC}"
        fi

        # Dependency indicator
        local dep_str=""
        if [ -n "$depends" ] && [ "$depends" != "None" ] && [ "$depends" != "none" ]; then
            dep_str="${DIM} ← ${depends}${NC}"
        fi

        # Children (tasks that depend on this one)
        local children=""
        while IFS=$'\t' read -r other_tid _ _ _ other_deps _ _ _; do
            [ "$other_tid" = "$tid" ] && continue
            if echo "$other_deps" | grep -q "$tid"; then
                children="${children:+${children}, }${other_tid}"
            fi
        done < <(parse_tasks "$task_file")

        local blocks_str=""
        if [ -n "$children" ]; then
            blocks_str="${DIM} → ${children}${NC}"
        fi

        # Format: icon tid [priority] title deps blocks │ start:end
        printf "  %b ${YELLOW}%-18s${NC} [%-2s] %-40s%b%b │ %d:%d\n" \
            "$icon" "$tid" "$priority" "$title" "$dep_str" "$blocks_str" "$start_line" "$end_line"
    done < <(parse_tasks "$task_file")
}

# Select tasks from parsed task data using fzf multi-select
select_tasks() {
    local task_file="$1"
    local repo_name="$2"
    local repo_path="$3"

    local tasks
    tasks=$(parse_tasks "$task_file")

    if [ -z "$tasks" ]; then
        log_error "No tasks found in file" >&2
        return 1
    fi

    local task_count
    task_count=$(echo "$tasks" | grep -c .)
    log_info "Found $task_count task(s)" >&2

    # Build topology-style lines for fzf
    local formatted
    formatted=$(build_topology_lines "$task_file" "$repo_name" "$METADATA_FILE" "$repo_path")

    local preview_script="$SCRIPT_DIR/task-preview.sh"

    local selected
    selected=$(echo -e "$formatted" | fzf \
        --ansi \
        --multi \
        --header="$(printf '═══ Task Topology ═══  ● active  ○ pending  ✓ done  ✗ dead\n\nTab: toggle  Enter: confirm  Esc: cancel')" \
        --layout=reverse \
        --preview="bash '$preview_script' {} '$task_file'" \
        --preview-window=right:65%:wrap \
        --bind='esc:cancel')

    if [ -z "$selected" ]; then
        return 1
    fi

    echo "$selected"
}

# Spawn worktree sessions for selected tasks
spawn_task_worktrees() {
    local task_file="$1"
    local selected_lines="$2"
    local repo_path="$3"
    local repo_name="$4"

    local created_sessions=()
    local failed_tasks=()
    local first_session=""

    while IFS= read -r line; do
        [ -z "$line" ] && continue

        # Extract fields from topology-style line:
        #   icon TASK-ID  [P1] Title text... │ start:end
        # Strip ANSI codes first
        local clean_line
        clean_line=$(echo "$line" | sed 's/\x1b\[[0-9;]*m//g')

        # Extract start:end from after the │ delimiter
        local range
        range=$(echo "$clean_line" | awk -F'│' '{gsub(/[[:space:]]/, "", $NF); print $NF}')
        local start_line end_line
        start_line=$(echo "$range" | cut -d: -f1)
        end_line=$(echo "$range" | cut -d: -f2)

        # Extract task_id: second word after stripping icon and whitespace
        local task_id
        task_id=$(echo "$clean_line" | awk -F'│' '{print $1}' | awk '{print $2}')

        # Extract title: text between [priority] and dependency/blocks markers
        local title
        title=$(echo "$clean_line" | awk -F'│' '{print $1}' | sed 's/.*\] *//' | sed 's/ *[←→].*//' | sed 's/[[:space:]]*$//')

        # Sanitize task ID for branch/path naming
        local sanitized_id
        sanitized_id=$(sanitize_name "$task_id")

        local branch_name="wt/${sanitized_id}"
        local topic="${sanitized_id}"
        local session_name
        session_name=$(generate_session_name "$repo_name" "$topic")
        local worktree_path
        worktree_path=$(get_worktree_path "$repo_name" "$sanitized_id")

        log_info "Creating: $task_id -> $session_name"

        # Check for existing session
        if session_exists "$session_name"; then
            log_warn "Session '$session_name' already exists, skipping"
            failed_tasks+=("$task_id (session exists)")
            continue
        fi

        # Create worktree
        create_worktree_for_branch "$repo_path" "$worktree_path" "$branch_name" "true"
        local wt_result=$?

        if [ "$wt_result" -eq 1 ]; then
            failed_tasks+=("$task_id (worktree error)")
            continue
        fi

        # Seed shared context from preamble (first spawn only)
        local shared_dir
        shared_dir="$(dirname "$worktree_path")/.shared"
        if [ ! -f "$shared_dir/context.md" ]; then
            extract_preamble "$task_file" > "$shared_dir/context.md"
            log_info "Seeded shared context from preamble"
        fi

        # Copy preamble + task block into the worktree (pure task content, no protocol)
        local branch_filename
        branch_filename=$(echo "$branch_name" | tr '/' '-')
        local task_output="$worktree_path/${branch_filename}.md"
        {
            extract_preamble "$task_file"
            echo ""
            echo "---"
            echo ""
            extract_task_block "$task_file" "$start_line" "$end_line"
        } > "$task_output"

        # Spawn session (auto_switch=false for batch mode)
        spawn_session_for_worktree "$session_name" "$repo_name" "$topic" \
            "$branch_name" "$worktree_path" "$repo_path" "$title" "false"
        local spawn_rc=$?

        if [ $spawn_rc -ne 0 ]; then
            failed_tasks+=("$task_id (session error)")
            continue
        fi

        # Write agent config file after spawn (now we know which agent was chosen)
        local agent_cmd_used
        agent_cmd_used=$(get_session_field "$session_name" "agent_cmd" 2>/dev/null)
        if [ -n "$agent_cmd_used" ]; then
            write_agent_config "$worktree_path" "$agent_cmd_used" "$task_id" "$branch_filename"
        fi

        created_sessions+=("$session_name")
        if [ -z "$first_session" ]; then
            first_session="$session_name"
        fi

    done <<< "$selected_lines"

    # Summary
    echo ""
    echo "═══════════════════════════════════════"
    if [ ${#created_sessions[@]} -gt 0 ]; then
        log_success "Created ${#created_sessions[@]} session(s):"
        for s in "${created_sessions[@]}"; do
            echo "  - $s"
        done
    fi

    if [ ${#failed_tasks[@]} -gt 0 ]; then
        log_warn "Failed ${#failed_tasks[@]} task(s):"
        for f in "${failed_tasks[@]}"; do
            echo "  - $f"
        done
    fi
    echo "═══════════════════════════════════════"

    # Switch to first created session
    if [ -n "$first_session" ]; then
        echo ""
        log_info "Switching to: $first_session"
        sleep 1
        switch_to_session "$first_session"
    fi
}

# Main workflow
main() {
    if ! is_git_repo; then
        log_error "Not in a git repository"
        exit 1
    fi

    local repo_path repo_name
    repo_path=$(get_repo_root)
    repo_name=$(get_repo_name "$repo_path")

    echo "=== Task Selector ==="
    echo ""

    # Stage 1: Browse for markdown file
    log_info "Select a task file..."
    local task_file
    task_file=$(browse_markdown_files "$repo_path")
    if [ $? -ne 0 ] || [ -z "$task_file" ]; then
        log_info "No file selected"
        exit 0
    fi

    log_info "Selected: $(basename "$task_file")"

    # Stage 2: Validate
    local validation_errors
    validation_errors=$(validate_task_file "$task_file" 2>&1)
    if [ $? -ne 0 ]; then
        log_error "Invalid task file:"
        echo "$validation_errors"
        echo ""
        echo "Press Enter to close..."
        read -r </dev/tty
        exit 1
    fi
    log_success "Valid task file"
    echo ""

    # Stage 3: Select tasks (with topology view)
    local selected
    selected=$(select_tasks "$task_file" "$repo_name" "$repo_path")
    if [ $? -ne 0 ] || [ -z "$selected" ]; then
        log_info "No tasks selected"
        exit 0
    fi

    # Stage 4: Confirm and spawn
    local count
    count=$(echo "$selected" | wc -l | tr -d ' ')
    echo ""
    if ! confirm "Create $count worktree session(s)?"; then
        log_info "Cancelled"
        exit 0
    fi

    echo ""
    spawn_task_worktrees "$task_file" "$selected" "$repo_path" "$repo_name"
}

# Run main
main "$@"
