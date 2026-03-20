#!/usr/bin/env bash
# Preview helper for task-selector fzf
# Usage: task-preview.sh <fzf-line> <task-file>

line="$1"
task_file="$2"

# Strip ANSI codes
clean=$(echo "$line" | sed $'s/\033\[[0-9;]*m//g')

# Extract start:end from after the │ delimiter
range=$(echo "$clean" | awk -F'│' '{gsub(/[[:space:]]/, "", $NF); print $NF}')
start=$(echo "$range" | cut -d: -f1)
end=$(echo "$range" | cut -d: -f2)

if [ -z "$start" ] || [ -z "$end" ] || [ "$start" -eq 0 ] 2>/dev/null; then
    echo "No preview available"
    exit 0
fi

# Show task block with syntax highlighting if bat is available
if command -v bat >/dev/null 2>&1; then
    sed -n "${start},${end}p" "$task_file" | bat --style=plain --color=always --language=markdown
else
    sed -n "${start},${end}p" "$task_file"
fi
