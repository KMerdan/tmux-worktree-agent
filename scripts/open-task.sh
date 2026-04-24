#!/usr/bin/env bash

# Open task.md or task-test.md in vim if found in the current pane's working
# directory or the git repo root. Does nothing if no matching file is found.
#
# Usage:
#   open-task.sh           # opens task.md (falls back to task-test.md)
#   open-task.sh test      # opens task-test.md only

set -e

variant="${1:-tasks}"

case "$variant" in
    tests|test)
        names=(task-test.md tasks-test.md TASK-TEST.md TASKS-TEST.md)
        ;;
    *)
        # Default: prefer task.md, fall back to task-test.md so the existing
        # binding still finds something when only the test variant exists.
        names=(task.md tasks.md TASK.md TASKS.md task-test.md tasks-test.md TASK-TEST.md TASKS-TEST.md)
        ;;
esac

# Try pane's current path first
pane_path="$(tmux display-message -p '#{pane_current_path}')"

# Search order: pane cwd, then git repo root
task_file=""
for dir in "$pane_path" "$(cd "$pane_path" && git rev-parse --show-toplevel 2>/dev/null)"; do
    [ -z "$dir" ] && continue
    for name in "${names[@]}"; do
        if [ -f "$dir/$name" ]; then
            task_file="$dir/$name"
            break 2
        fi
    done
done

if [ -z "$task_file" ]; then
    echo "No matching task file found"
    sleep 1
    exit 0
fi

vim "$task_file"
