#!/usr/bin/env bash

# Sends a prompt to the current pane's agent to generate a task markdown file
# following the tmux-worktree-agent task parser format

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"

# The prompt template that instructs the agent to generate a task markdown
TASK_PROMPT='Based on what we discussed, create a `task.md` file in the repository root that breaks down the work into separate, non-conflicting tasks. Each task must be independently implementable in its own git worktree without merge conflicts with other tasks.

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

Write the file now.'

main() {
    local current_session
    current_session=$(get_current_session 2>/dev/null)

    if [ -z "$current_session" ]; then
        log_error "Not in a tmux session"
        exit 1
    fi

    # Get the current pane
    local pane_id
    pane_id=$(tmux display-message -p '#{pane_id}')

    # Check if there's an agent-like process in the current pane
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

    # Send the prompt to the current pane
    # Use tmux load-buffer + paste to handle multi-line text cleanly
    local tmpfile
    tmpfile=$(mktemp)
    echo "$TASK_PROMPT" > "$tmpfile"

    tmux load-buffer "$tmpfile"
    tmux paste-buffer -t "$pane_id"
    # Send Enter to submit
    tmux send-keys -t "$pane_id" C-m

    rm -f "$tmpfile"

    log_success "Task generation prompt sent to agent"
}

main "$@"
