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

# Extract scoped file paths from a task block
# Parses the **Scoped Files** section, extracts backtick-quoted paths
# Input: task file path, start_line, end_line
# Output: newline-separated file paths (stripped of backticks and descriptions)
extract_scoped_files() {
    local filepath="$1"
    local start_line="$2"
    local end_line="$3"

    sed -n "${start_line},${end_line}p" "$filepath" | awk '
        /^\*\*Scoped Files\*\*/ { capture=1; next }
        /^\*\*[A-Z]/ { if (capture) exit }
        capture && /`[^`]+`/ {
            line = $0
            match(line, /`[^`]+`/)
            if (RSTART > 0) {
                path = substr(line, RSTART+1, RLENGTH-2)
                print path
            }
        }
    '
}

# Extract the preamble (everything before the first --- separator)
# This is shared context that should be included with every task
extract_preamble() {
    local filepath="$1"

    awk '/^---[[:space:]]*$/ { exit } { print }' "$filepath"
}
