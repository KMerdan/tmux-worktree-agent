#!/usr/bin/env bash

# Preview script for task-prompt-menu fzf
# Arg 1: the selected menu line
# Arg 2: prompts directory (optional, for custom prompts)

selection="$1"
prompts_dir="$2"

BOLD=$'\033[1m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
NC=$'\033[0m'

case "$selection" in
    "Start sub-agent task")
        echo "${BOLD}Start Sub-Agent Task${NC}"
        echo ""
        echo "Sends a prompt to the agent in the current pane to:"
        echo ""
        echo "  1. Read its task file and .shared/context.md"
        echo "  2. Check .shared/broadcasts/ for updates from other agents"
        echo "  3. Fact-check assumptions against the codebase"
        echo "  4. Begin implementing only after verification"
        echo "  5. Commit work and write broadcast when done"
        echo ""
        echo "${DIM}Includes dynamic branch context (your branch + parent/merge target).${NC}"
        echo "${DIM}Explicitly tells the agent: do NOT merge.${NC}"
        ;;
    "Generate task.md")
        echo "${BOLD}Generate task.md${NC}"
        echo ""
        echo "Asks the agent to create a structured task.md that breaks"
        echo "work into independent, non-conflicting tasks for parallel"
        echo "worktree execution."
        echo ""
        echo "The generated file includes:"
        echo "  • Shared context preamble (copied to every agent)"
        echo "  • Task blocks with: ID, title, scoped files, interfaces"
        echo "  • Dependency graph (Depends On / Blocks)"
        echo "  • Branch strategy auto-filled from current branch + SHA"
        echo ""
        echo "${DIM}Format is strict — consumed by the task parser.${NC}"
        ;;
    "Merge completed tasks")
        echo "${BOLD}Merge Completed Tasks${NC}"
        echo ""
        echo "Launches the merge orchestrator which:"
        echo ""
        echo "  1. Reads broadcasts from all completed agents"
        echo "  2. Checks dependency order from task.md"
        echo "  3. Fact-checks each branch's diff against its broadcast"
        echo "  4. Merges branches into the parent branch in order"
        echo "  5. Kills completed sessions after merge"
        echo ""
        echo "${DIM}Uses parent_branch from metadata (not hardcoded main).${NC}"
        echo "${DIM}Stops on merge conflicts — does not force resolve.${NC}"
        ;;
    "Update constraints")
        echo "${BOLD}Update Constraints${NC}"
        echo ""
        echo "Reviews the Shared Constraints section of task.md against"
        echo "recent git history. Detects stale constraints like:"
        echo ""
        echo "  • \"Do NOT modify X\" when X has been actively modified"
        echo "  • Scoped file conflicts between tasks"
        echo "  • Outdated dependency notes"
        echo ""
        echo "${DIM}Injects the last 20 commits and changed files for context.${NC}"
        echo "${DIM}Only modifies the preamble, not individual task blocks.${NC}"
        ;;
    "Simplify project")
        echo "${BOLD}Simplify Project${NC}"
        echo ""
        echo "First-principles subtraction analysis. For every module:"
        echo ""
        echo "  • Line count vs value delivered"
        echo "  • Core alignment — does it serve the main value prop?"
        echo "  • Usage frequency — daily? weekly? once ever?"
        echo "  • Blast radius of deletion"
        echo "  • Simpler alternatives"
        echo ""
        echo "${DIM}Ranks everything from most to least deletable.${NC}"
        echo "${DIM}Targets at least 10% of the codebase for removal.${NC}"
        ;;
    "Manage custom prompts")
        echo "${BOLD}Manage Custom Prompts${NC}"
        echo ""
        echo "Add, edit, or remove project-specific prompts."
        echo "Up to 3 custom prompts per project."
        echo ""
        echo "Prompts are stored in:"
        echo "  ${CYAN}~/.worktrees/<repo>/.prompts/<name>.md${NC}"
        echo ""
        echo "File format:"
        echo "  Line 1: # Title (shown in menu)"
        echo "  Rest:   Prompt body (sent to agent)"
        echo ""
        echo "${DIM}Uses \$EDITOR (defaults to vim) for editing.${NC}"
        ;;
    ★*)
        # Custom prompt — show file content
        selected_title="${selection#★ }"
        if [ -n "$prompts_dir" ] && [ -d "$prompts_dir" ]; then
            for f in "$prompts_dir"/*.md; do
                [ -f "$f" ] || continue
                title=$(head -1 "$f" 2>/dev/null | sed 's/^#* *//')
                if [ "$title" = "$selected_title" ]; then
                    echo "${BOLD}${title}${NC}"
                    echo "${DIM}$(basename "$f")${NC}"
                    echo ""
                    tail -n +2 "$f"
                    break
                fi
            done
        fi
        ;;
    ──*)
        # Separator — no preview
        ;;
    *)
        echo "${DIM}No preview available${NC}"
        ;;
esac
