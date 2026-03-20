#!/usr/bin/env bash

# Task markdown parser for tmux-worktree-agent
# Parses markdown files with tasks separated by --- horizontal rules
#
# Expected task format:
#   ### Task ID: TASK-xxx
#   **Title**: Some title
#   **Status**: `[ ]` pending     (optional)
#   **Priority**: P1              (optional)
#   ... additional content ...
#
# Tasks are separated by --- horizontal rules.
# Content before the first --- (preamble) is silently ignored.

# Validate that a file follows the task markdown format
# Returns 0 on success, 1 on failure (errors printed to stderr)
validate_task_file() {
    local filepath="$1"

    if [ ! -f "$filepath" ] || [ ! -r "$filepath" ]; then
        echo "File not found or not readable: $filepath" >&2
        return 1
    fi

    # Count task ID headers in the entire file
    local taskid_count
    taskid_count=$(grep -c '^### Task ID:' "$filepath" 2>/dev/null || true)

    if [ "$taskid_count" -eq 0 ]; then
        echo "No '### Task ID:' headers found. Each task must start with '### Task ID: <id>'." >&2
        return 1
    fi

    # Single task with no separator is valid
    if [ "$taskid_count" -eq 1 ]; then
        local separator_count
        separator_count=$(grep -cE '^---[[:space:]]*$' "$filepath" 2>/dev/null || true)

        # Validate the single task has a title
        if ! grep -q '^\*\*Title\*\*:' "$filepath"; then
            echo "Task is missing '**Title**:' field." >&2
            return 1
        fi

        return 0
    fi

    # Multiple tasks require separators
    local separator_count
    separator_count=$(grep -cE '^---[[:space:]]*$' "$filepath" 2>/dev/null || true)

    if [ "$separator_count" -eq 0 ]; then
        echo "No '---' horizontal rule separators found. Tasks must be separated by '---'." >&2
        return 1
    fi

    # Validate each block between separators
    local errors=()
    local block_num=0
    local current_block=""
    local has_taskid=false
    local has_title=false

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^---[[:space:]]*$ ]]; then
            # Process completed block
            if [ -n "$current_block" ]; then
                # Only validate blocks that look like tasks (have Task ID or Title)
                if echo "$current_block" | grep -q '^\*\*Title\*\*:\|^### Task ID:'; then
                    ((block_num++))
                    if ! echo "$current_block" | grep -q '^### Task ID:'; then
                        errors+=("Block $block_num: missing '### Task ID:' header")
                    fi
                    if ! echo "$current_block" | grep -q '^\*\*Title\*\*:'; then
                        errors+=("Block $block_num: missing '**Title**:' field")
                    fi
                fi
                # else: preamble/non-task block, silently skip
            fi
            current_block=""
        else
            current_block+="$line"$'\n'
        fi
    done < "$filepath"

    # Validate last block (after final ---)
    if [ -n "$current_block" ]; then
        if echo "$current_block" | grep -q '^\*\*Title\*\*:\|^### Task ID:'; then
            ((block_num++))
            if ! echo "$current_block" | grep -q '^### Task ID:'; then
                errors+=("Block $block_num: missing '### Task ID:' header")
            fi
            if ! echo "$current_block" | grep -q '^\*\*Title\*\*:'; then
                errors+=("Block $block_num: missing '**Title**:' field")
            fi
        fi
    fi

    if [ ${#errors[@]} -gt 0 ]; then
        echo "Validation errors:" >&2
        for e in "${errors[@]}"; do
            echo "  - $e" >&2
        done
        return 1
    fi

    if [ "$block_num" -eq 0 ]; then
        echo "No valid task blocks found." >&2
        return 1
    fi

    return 0
}

# Parse tasks from a markdown file
# Outputs tab-separated lines: task_id\ttitle\tstatus\tpriority\tdepends_on\tblocks\tstart_line\tend_line
parse_tasks() {
    local filepath="$1"

    awk '
    BEGIN {
        block_start = 1
        block = ""
        block_line_start = 1
    }

    /^---[[:space:]]*$/ {
        if (block != "") {
            process_block(block, block_line_start, NR - 1)
        }
        block = ""
        block_line_start = NR + 1
        next
    }

    {
        if (block == "") {
            block_line_start = NR
        }
        block = block $0 "\n"
    }

    END {
        if (block != "") {
            process_block(block, block_line_start, NR)
        }
    }

    function process_block(text, start, end,    task_id, title, status, priority, depends_on, blocks, n, lines, i, line, val) {
        task_id = ""
        title = ""
        status = ""
        priority = ""
        depends_on = ""
        blocks = ""

        n = split(text, lines, "\n")
        for (i = 1; i <= n; i++) {
            line = lines[i]

            # Extract Task ID
            if (task_id == "" && index(line, "### Task ID:") == 1) {
                val = line
                sub(/^### Task ID:[[:space:]]*/, "", val)
                task_id = val
            }

            # Extract Title
            if (title == "" && index(line, "**Title**:") == 1) {
                val = line
                sub(/^\*\*Title\*\*:[[:space:]]*/, "", val)
                title = val
            }

            # Extract Status
            if (status == "" && index(line, "**Status**:") == 1) {
                val = line
                sub(/^\*\*Status\*\*:[[:space:]]*/, "", val)
                status = val
            }

            # Extract Priority
            if (priority == "" && index(line, "**Priority**:") == 1) {
                val = line
                sub(/^\*\*Priority\*\*:[[:space:]]*/, "", val)
                priority = val
            }

            # Extract Depends On
            if (depends_on == "" && index(line, "**Depends On**:") == 1) {
                val = line
                sub(/^\*\*Depends On\*\*:[[:space:]]*/, "", val)
                depends_on = val
            }

            # Extract Blocks
            if (blocks == "" && index(line, "**Blocks**:") == 1) {
                val = line
                sub(/^\*\*Blocks\*\*:[[:space:]]*/, "", val)
                blocks = val
            }
        }

        if (task_id != "") {
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\n", task_id, title, status, priority, depends_on, blocks, start, end
        }
    }
    ' "$filepath"
}

# Extract the raw markdown block for a task given start and end line numbers
extract_task_block() {
    local filepath="$1"
    local start_line="$2"
    local end_line="$3"

    sed -n "${start_line},${end_line}p" "$filepath"
}

# Extract the preamble (everything before the first --- separator)
# This is shared context that should be included with every task
extract_preamble() {
    local filepath="$1"

    awk '/^---[[:space:]]*$/ { exit } { print }' "$filepath"
}

# Render a topology view of tasks with dependency edges and spawn status
# Args: task_file metadata_file repo_name
# Reads parse_tasks output and cross-references with metadata to show:
#   ● = worktree active, ○ = not spawned, ✓ = completed
render_topology() {
    local task_file="$1"
    local metadata_file="$2"
    local repo_name="$3"
    local repo_path="$4"

    # Colors
    local GREEN='\033[0;32m'
    local YELLOW='\033[1;33m'
    local BLUE='\033[0;34m'
    local CYAN='\033[0;36m'
    local DIM='\033[2m'
    local NC='\033[0m'

    # Parse all tasks into arrays
    local -a task_ids=()
    local -a task_titles=()
    local -a task_priorities=()
    local -a task_statuses=()
    local -a task_depends=()
    local -a task_blocks=()

    while IFS=$'\t' read -r tid title task_status priority depends blocks start_line end_line; do
        task_ids+=("$tid")
        task_titles+=("$title")
        task_statuses+=("$task_status")
        task_priorities+=("$priority")
        task_depends+=("$depends")
        task_blocks+=("$blocks")
    done < <(parse_tasks "$task_file")

    local total=${#task_ids[@]}
    if [ "$total" -eq 0 ]; then
        echo "No tasks found"
        return
    fi

    # Check spawn status for each task from metadata
    local -a spawn_status=()
    local -a spawn_info=()
    for i in $(seq 0 $((total - 1))); do
        local tid="${task_ids[$i]}"
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
        local agent_cmd="" branch=""
        if [ "$has_metadata" = true ]; then
            agent_cmd=$(jq -r --arg s "$session_name" '.[$s].agent_cmd // ""' "$metadata_file")
            branch=$(jq -r --arg s "$session_name" '.[$s].branch // ""' "$metadata_file")
            if tmux has-session -t "$session_name" 2>/dev/null; then
                has_session=true
            fi
        fi

        # Check if branch has been merged into main (existing or deleted)
        local is_merged=false
        if [ -n "$repo_path" ]; then
            if git -C "$repo_path" branch --merged main 2>/dev/null | sed 's/^[*+ ] //' | grep -qx "$branch_name"; then
                is_merged=true
            elif git -C "$repo_path" log --merges --oneline main 2>/dev/null | grep -q "Merge branch '${branch_name}'"; then
                is_merged=true
            fi
        fi

        # Priority: active session > merged > markdown [x] > dead session > pending
        if [ "$has_session" = true ]; then
            spawn_status+=("active")
            spawn_info+=("${agent_cmd:-agent}:${branch}")
        elif [ "$is_merged" = true ]; then
            spawn_status+=("completed")
            spawn_info+=("")
        elif echo "${task_statuses[$i]}" | grep -q '\[x\]'; then
            spawn_status+=("completed")
            spawn_info+=("")
        elif [ "$has_metadata" = true ]; then
            spawn_status+=("dead")
            spawn_info+=("session gone")
        else
            spawn_status+=("none")
            spawn_info+=("")
        fi
    done

    # Build dependency map: for each task, find which tasks depend on it (children)
    # A "depends on B" means B -> A (B must come first, A is downstream)
    local -a has_parent=()
    for i in $(seq 0 $((total - 1))); do
        has_parent+=("false")
    done

    # Print header
    echo -e "${CYAN}═══ Task Topology ═══${NC}"
    echo -e "${DIM}● active  ○ pending  ✓ done  ✗ dead${NC}"
    echo ""

    # For each task, render it with its status and edges
    for i in $(seq 0 $((total - 1))); do
        local tid="${task_ids[$i]}"
        local title="${task_titles[$i]}"
        local priority="${task_priorities[$i]}"
        local depends="${task_depends[$i]}"
        local sp_status="${spawn_status[$i]}"
        local info="${spawn_info[$i]}"

        # Status icon
        local icon
        case "$sp_status" in
            active)    icon="${GREEN}●${NC}" ;;
            completed) icon="${GREEN}✓${NC}" ;;
            dead)      icon="\033[0;31m✗${NC}" ;;
            *)         icon="${DIM}○${NC}" ;;
        esac

        # Dependency indicator
        local dep_str=""
        if [ -n "$depends" ] && [ "$depends" != "None" ] && [ "$depends" != "none" ]; then
            dep_str="${DIM} ← ${depends}${NC}"
        fi

        # Info string (agent:branch for active sessions)
        local info_str=""
        if [ -n "$info" ]; then
            info_str="${DIM} (${info})${NC}"
        fi

        # Find children (tasks that depend on this one)
        local children=""
        for j in $(seq 0 $((total - 1))); do
            if [ "$j" -eq "$i" ]; then continue; fi
            local other_deps="${task_depends[$j]}"
            if echo "$other_deps" | grep -q "$tid"; then
                if [ -n "$children" ]; then
                    children="${children}, ${task_ids[$j]}"
                else
                    children="${task_ids[$j]}"
                fi
            fi
        done

        # Render task line
        echo -e "  ${icon} ${YELLOW}${tid}${NC} [${priority}] ${title}${dep_str}${info_str}"

        # Render children edges
        if [ -n "$children" ]; then
            echo -e "    ${DIM}└──→ blocks: ${children}${NC}"
        fi
    done

    echo ""
    echo -e "${DIM}${total} task(s)${NC}"
}
