#!/usr/bin/env bash

# Open task.md in vim if it exists in the current pane's working directory
# or the git repo root. Does nothing if no task.md is found.

set -e

# Try pane's current path first
pane_path="$(tmux display-message -p '#{pane_current_path}')"

# Search order: pane cwd, then git repo root
task_file=""
for dir in "$pane_path" "$(cd "$pane_path" && git rev-parse --show-toplevel 2>/dev/null)"; do
    [ -z "$dir" ] && continue
    for name in task.md tasks.md TASK.md TASKS.md; do
        if [ -f "$dir/$name" ]; then
            task_file="$dir/$name"
            break 2
        fi
    done
done

if [ -z "$task_file" ]; then
    echo "No task.md found"
    sleep 1
    exit 0
fi

vim "$task_file"
