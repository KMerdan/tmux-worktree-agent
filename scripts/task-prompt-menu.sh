#!/usr/bin/env bash

# Task prompt menu — unified entry point for task-related prompt injections
# Presents a menu: Generate / Merge / Update, then delegates to the appropriate script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"

trap 'rc=$?; if [ $rc -ne 0 ]; then sleep 1.5; fi; exit $rc' EXIT

main() {
    local action
    action=$(printf "Start sub-agent task\nGenerate task.md\nMerge completed tasks\nUpdate constraints" | fzf \
        --ansi \
        --header="Task Prompts — select an action" \
        --layout=reverse \
        --height=8 \
        --no-preview \
        --bind='esc:cancel')

    if [ -z "$action" ]; then
        exit 0
    fi

    case "$action" in
        "Start sub-agent task")
            exec "$SCRIPT_DIR/start-task-prompt.sh"
            ;;
        "Generate task.md")
            exec "$SCRIPT_DIR/generate-task-prompt.sh"
            ;;
        "Merge completed tasks")
            exec "$SCRIPT_DIR/merge-orchestrator.sh"
            ;;
        "Update constraints")
            exec "$SCRIPT_DIR/update-constraints.sh"
            ;;
    esac
}

main "$@"
