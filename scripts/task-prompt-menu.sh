#!/usr/bin/env bash

# Task prompt menu — unified entry point for task-related prompt injections
# Consolidates: start-task-prompt, generate-task-prompt, update-constraints
# Delegates merge to merge-orchestrator.sh (fundamentally different workflow)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"

trap 'rc=$?; if [ $rc -ne 0 ]; then sleep 1.5; fi; exit $rc' EXIT

# ---------------------------------------------------------------------------
# Shared: detect agent and paste prompt into current pane
# ---------------------------------------------------------------------------
send_prompt_to_agent() {
    local prompt_text="$1"
    local success_msg="$2"

    local current_session
    current_session=$(get_current_session 2>/dev/null)

    if [ -z "$current_session" ]; then
        log_error "Not in a tmux session"
        exit 1
    fi

    local pane_id
    pane_id=$(tmux display-message -p '#{pane_id}')

    local pane_pid
    pane_pid=$(tmux display-message -p '#{pane_pid}')

    local agent_cmd="${WORKTREE_AGENT_CMD:-claude}"
    local agent_process="${agent_cmd%% *}"

    local has_agent=false
    if find_agent_pid "$pane_pid" "$agent_process" >/dev/null 2>&1; then
        has_agent=true
    fi

    if [ "$has_agent" = false ]; then
        log_warn "No agent process detected in current pane"
        echo "Send prompt anyway? (y/N)"
        local response
        read -r response </dev/tty 2>/dev/null || read -r response
        case "$response" in
            [yY]|[yY][eE][sS]) ;;
            *) exit 0 ;;
        esac
    fi

    local tmpfile
    tmpfile=$(mktemp)
    echo "$prompt_text" > "$tmpfile"

    tmux load-buffer "$tmpfile"
    tmux paste-buffer -t "$pane_id"
    tmux send-keys -t "$pane_id" C-m

    rm -f "$tmpfile"

    log_success "$success_msg"
    sleep 1
}

# ---------------------------------------------------------------------------
# Prompt: Start sub-agent task
# ---------------------------------------------------------------------------
prompt_start_task() {
    local text='Load the task and understand it fully before writing any code.

1. Read your task file and `.shared/context.md` to understand the full scope
2. Check `.shared/broadcasts/` for updates from other agents working on parallel tasks
3. Fact-check every assumption against the actual codebase — read the relevant files, trace the code paths, verify interfaces and types exist as described
4. Only after you have confirmed your understanding matches reality, begin implementing'

    send_prompt_to_agent "$text" "Start task prompt sent to agent"
}

# ---------------------------------------------------------------------------
# Prompt: Generate task.md
# ---------------------------------------------------------------------------
prompt_generate_tasks() {
    local text='Based on what we discussed, create a `task.md` file in the repository root that breaks down the work into separate, non-conflicting tasks. Each task must be independently implementable in its own git worktree without merge conflicts with other tasks.

IMPORTANT: A parser will consume this file. The format below is strict — do not deviate.

The file has TWO sections:
1. **Shared Context (preamble)** — everything BEFORE the first `---`. This is copied to EVERY spawned agent as shared memory. Put all cross-task knowledge here.
2. **Task blocks** — separated by `---`. Each is assigned to one agent in an isolated worktree.

```
# <Project/Feature Name> — Development Tasks

**Last Updated**: <date>

## Project Overview
<What is this project? What are we building/changing and why?>

## Architecture & Conventions
- <Tech stack, frameworks, language versions>
- <Key architectural patterns (e.g., "all API routes go through /src/api/router.ts")>
- <Naming conventions, file organization rules>
- <Testing requirements (e.g., "every new module needs unit tests in __tests__/")>

## Shared Constraints
- <Files/modules that are FROZEN and must NOT be modified by any task>
- <External dependencies or API contracts that all tasks must respect>
- <Performance budgets, security requirements, compliance rules>
- <Branch/merge strategy (e.g., "all tasks branch from main at commit abc123")>

## Cross-Task Dependencies
<Brief map of how tasks relate — which produces interfaces others consume, ordering constraints>

---

### Task ID: TASK-<short-id>
**Title**: <concise title>
**Status**: `[ ]` pending
**Priority**: P<0-5>
**Depends On**: <TASK-xxx, TASK-yyy or None>
**Blocks**: <TASK-zzz or None>

**Problem/Goal**:
<2-3 sentences — what needs to be done, why it matters, what success looks like>

**Scoped Files** (ONLY touch these):
- `<path/to/file.ts>` — <what to change and why>
- `<path/to/new-file.ts>` — <create: purpose>
- `<path/to/tests/>` — <test files to add/modify>

**Shared Interfaces** (contracts with other tasks):
- <Exports/APIs this task produces that other tasks depend on>
- <Imports/APIs this task consumes from other tasks>
- <If none, write "None — fully independent">

**Acceptance Criteria**:
- [ ] <specific, testable outcome>
- [ ] <specific, testable outcome>
- [ ] <tests pass: describe what tests to write>

**Implementation Notes**:
<Step-by-step approach, patterns to follow, edge cases, gotchas>
<Reference to existing code patterns in the codebase to follow>

**Out of Scope**:
<Explicitly state what this task should NOT do to prevent overlap>

---

### Task ID: TASK-<next-id>
...
```

Rules:
1. Every task block MUST start with `### Task ID: TASK-<id>` — the parser keys on this
2. Every task block MUST have `**Title**:` on its own line — the parser requires this
3. Tasks MUST be separated by `---` (horizontal rule on its own line)
4. The preamble (before first `---`) is shared context — make it rich and complete
5. Task IDs: short, descriptive kebab-case (e.g., TASK-auth, TASK-ocr, TASK-api-routes). Each task will be spawned on a `wt/<sanitized-task-id>` branch in its own worktree
6. **Scoped Files** is critical: each task MUST list exactly which files it will touch. Two tasks MUST NOT have overlapping scoped files — this prevents merge conflicts across worktrees
7. **Shared Interfaces**: when tasks need to coordinate (e.g., one creates a type another imports), define the contract explicitly so both agents agree on the shape
8. **Out of Scope**: explicitly prevent agents from drifting into other tasks'\'' territory
9. Set **Depends On** / **Blocks** when task ordering matters
10. The preamble should contain enough context that an agent reading ONLY the preamble + its task block can work independently without asking questions
11. Each spawned agent gets a `.shared/` directory (symlinked across all worktrees for the same repo) with:
    - `.shared/context.md` — seeded from the preamble, read-only for agents
    - `.shared/broadcasts/` — each agent writes ONLY `.shared/broadcasts/TASK-<its-id>.md` to communicate changes that affect other tasks
    Include a note in the preamble telling agents about this shared knowledge protocol so they know to check `.shared/broadcasts/` for updates from other tasks and write their own when making cross-task changes.

Write the file now.'

    send_prompt_to_agent "$text" "Task generation prompt sent to agent"
}

# ---------------------------------------------------------------------------
# Prompt: Update constraints
# ---------------------------------------------------------------------------
prompt_update_constraints() {
    # Gather git context from pane's cwd
    local pane_cwd
    pane_cwd=$(tmux display-message -p '#{pane_current_path}')

    local repo_path
    repo_path=$(cd "$pane_cwd" && git rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$repo_path" ]; then
        log_error "Not in a git repository"
        exit 1
    fi

    local recent_changes
    recent_changes=$(cd "$repo_path" && git log --oneline -20 2>/dev/null)

    local changed_files
    changed_files=$(cd "$repo_path" && git log --name-only --pretty=format: -20 2>/dev/null | sort -u | grep -v '^$')

    local text
    text="Review and update the \`task.md\` file in the repo root. The shared constraints section may be stale — files listed as \"do not modify\" may have been heavily modified since the task.md was written.

## Recent Git History
\`\`\`
${recent_changes}
\`\`\`

## Files Changed Recently
\`\`\`
${changed_files}
\`\`\`

## Your Job

1. Read the \`## Shared Constraints\` section in task.md
2. For each \"Do NOT modify\" constraint, check if that file has been modified in recent commits
3. If a constraint is stale (the file has been actively modified), either:
   - Remove the constraint if the file is now stable and open for changes
   - Update the constraint to reflect the current state (e.g., \"Do NOT modify X except for Y\")
4. Check if any task's \`**Scoped Files**\` conflicts with the shared constraints — flag these
5. Also update the \`## Cross-Task Dependencies\` section:
   - Mark completed tasks (check \`**Status**: [x] done\`)
   - Update dependency notes for remaining tasks

## Rules
- Only modify the preamble (before the first \`---\`), not individual task blocks
- Keep constraints that are still valid
- Be specific about what changed and why a constraint was removed/updated
- Do NOT change task IDs, titles, or acceptance criteria"

    send_prompt_to_agent "$text" "Update constraints prompt sent to agent"
}

# ---------------------------------------------------------------------------
# Prompt: Simplify project (first-principles subtraction)
# ---------------------------------------------------------------------------
prompt_simplify_project() {
    # Gather project stats
    local pane_cwd
    pane_cwd=$(tmux display-message -p '#{pane_current_path}')

    local repo_path
    repo_path=$(cd "$pane_cwd" && git rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$repo_path" ]; then
        log_error "Not in a git repository"
        exit 1
    fi

    local repo_name
    repo_name=$(basename "$repo_path")

    # Collect file/line stats for context
    local file_stats
    file_stats=$(cd "$repo_path" && find . -name '*.sh' -o -name '*.py' -o -name '*.ts' -o -name '*.js' -o -name '*.go' -o -name '*.rs' -o -name '*.rb' -o -name '*.lua' 2>/dev/null \
        | grep -v node_modules | grep -v vendor | grep -v '.git/' \
        | head -50 \
        | while read -r f; do
            lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
            echo "  $lines $f"
        done | sort -rn)

    local text
    text="Analyze this project from a first-principles subtraction perspective.

## Project
**Repo**: ${repo_name}
**Path**: ${repo_path}

## File sizes (top files by line count)
\`\`\`
${file_stats}
\`\`\`

## Instructions

First, state the core value proposition in ONE sentence — what does this project do that nothing else does?

Then for EVERY module/script/component:

1. **Line count** — how much code does it cost to maintain?
2. **Core alignment** — does it directly serve the core value prop, or is it adjacent/nice-to-have?
3. **Usage frequency** — how often does a real user actually trigger this? Daily? Weekly? Once ever?
4. **Blast radius of deletion** — what breaks if removed? Is anything coupled to it?
5. **Simpler alternative** — could the user achieve the same result with a 1-2 line command, an existing tool, or a README paragraph?

Rank EVERY component from \"most deletable\" to \"least deletable.\"

Ranking criteria (in order of weight):
- Lines of code maintained relative to value delivered
- Whether it solves a problem users ACTUALLY have vs a hypothetical one
- Whether the same outcome is achievable with existing tools at negligible cost
- How many other components depend on it (coupling)
- Whether it introduces an entire new CATEGORY of responsibility that is not the project's job

Be ruthless — if you're not recommending deleting at least 10% of the codebase, you're not looking hard enough.

At the end, identify the ABSOLUTE ESSENTIAL set — the files without which the core value prop ceases to exist. Everything else is a deletion candidate.

Present your findings as a ranked table, then give me your top 3 recommended deletions with the exact files and line savings."

    send_prompt_to_agent "$text" "Simplify project prompt sent to agent"
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
main() {
    local action
    action=$(printf "Start sub-agent task\nGenerate task.md\nMerge completed tasks\nUpdate constraints\nSimplify project" | fzf \
        --ansi \
        --header="Task Prompts — select an action" \
        --layout=reverse \
        --height=100% \
        --no-preview \
        --bind='esc:cancel')

    if [ -z "$action" ]; then
        exit 0
    fi

    case "$action" in
        "Start sub-agent task")
            prompt_start_task
            ;;
        "Generate task.md")
            prompt_generate_tasks
            ;;
        "Merge completed tasks")
            exec "$SCRIPT_DIR/merge-orchestrator.sh"
            ;;
        "Update constraints")
            prompt_update_constraints
            ;;
        "Simplify project")
            prompt_simplify_project
            ;;
    esac
}

main "$@"
