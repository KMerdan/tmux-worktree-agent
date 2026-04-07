#!/usr/bin/env bash

# Task prompt menu — unified entry point for task-related prompt injections
# Consolidates: start-task-prompt, generate-task-prompt, update-constraints
# Delegates merge to merge-orchestrator.sh (fundamentally different workflow)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"

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
    # Gather dynamic branch context
    local pane_cwd
    pane_cwd=$(tmux display-message -p '#{pane_current_path}')

    local current_branch=""
    local parent_branch=""
    if cd "$pane_cwd" 2>/dev/null && git rev-parse --show-toplevel >/dev/null 2>&1; then
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    fi

    # Read parent_branch from metadata (stored at spawn time, not from current main repo HEAD)
    local current_session
    current_session=$(get_current_session 2>/dev/null)
    if [ -n "$current_session" ]; then
        parent_branch=$(get_session_field "$current_session" "parent_branch")
    fi

    local branch_context=""
    if [ -n "$current_branch" ]; then
        branch_context="
## Branch Context
- **Your branch**: \`${current_branch}\`"
        if [ -n "$parent_branch" ]; then
            branch_context+="
- **Parent branch (merge target)**: \`${parent_branch}\`"
        fi
        branch_context+="
- **Do NOT merge** — commit your work and write your broadcast when done. Merging is handled separately by the orchestrator."
    fi

    local text="Load the task and understand it fully before writing any code.
${branch_context}

1. Read your task file and \`.shared/context.md\` to understand the full scope
2. Check \`.shared/broadcasts/\` for updates from other agents working on parallel tasks
3. Fact-check every assumption against the actual codebase — read the relevant files, trace the code paths, verify interfaces and types exist as described
4. Only after you have confirmed your understanding matches reality, begin implementing
5. When finished, commit all changes and write your broadcast to \`.shared/broadcasts/TASK-<your-id>.md\` — do NOT merge into any branch"

    send_prompt_to_agent "$text" "Start task prompt sent to agent"
}

# ---------------------------------------------------------------------------
# Prompt: Generate task.md
# ---------------------------------------------------------------------------
prompt_generate_tasks() {
    # Gather dynamic branch context
    local pane_cwd
    pane_cwd=$(tmux display-message -p '#{pane_current_path}')

    local current_branch=""
    local short_sha=""
    local repo_path=""
    repo_path=$(cd "$pane_cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || true
    if [ -n "$repo_path" ]; then
        current_branch=$(cd "$repo_path" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
        short_sha=$(cd "$repo_path" && git rev-parse --short HEAD 2>/dev/null)
    fi

    # Inject orchestrator config into project CLAUDE.md
    if [ -n "$repo_path" ]; then
        inject_orchestrator_config "$repo_path"
        log_info "Updated orchestrator config in CLAUDE.md"
    fi

    local branch_strategy=""
    if [ -n "$current_branch" ] && [ -n "$short_sha" ]; then
        branch_strategy="- Branch/merge strategy: all tasks branch from \`${current_branch}\` at commit \`${short_sha}\`. Merging back into \`${current_branch}\` is handled by the orchestrator — agents must NOT merge."
    fi

    local wta_path="$PLUGIN_DIR/scripts/wta.sh"

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
'"${branch_strategy:-- <Branch/merge strategy (e.g., \"all tasks branch from dev-branch at commit abc123\")>}"'

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
4. The preamble (before first `---`) is shared context ��� make it rich and complete
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

After writing task.md:

1. **Scaffold `.agent-docs/` if it does not exist.** This is the progressive disclosure documentation pyramid for agents. Create:
   - `.agent-docs/AGENTS.md` — routing layer (~60 lines): module/crate boundaries table + "before touching X, read Y" table pointing to context files. NO implementation details here — just routing.
   - `.agent-docs/context/<domain>.md` — one file per distinct domain in the project (~60-100 lines each). Examples: `backend.md`, `frontend.md`, `database.md`, `engine.md`, `pipeline.md`. Each file covers ONE domain with: key types/interfaces, patterns to follow, conventions, gotchas. An agent touching only that domain reads only that file.
   - `.agent-docs/README.md` — index of all files in the pyramid.
   - Move any existing deep design docs (architecture, design specs, API references) into `.agent-docs/architecture/`, `.agent-docs/design/`, or `.agent-docs/guides/` as Layer 4 reference docs.
   If `.agent-docs/` already exists, review and update it to reflect current architecture — do not recreate from scratch.

2. **Update CLAUDE.md** (Layer 1) to include the documentation table pointing to `.agent-docs/` layers. Keep CLAUDE.md under ~120 lines — it should contain project identity, build commands, rules, and a routing table to `.agent-docs/`. Check your CLAUDE.md for the pyramid maintenance rules and follow them.

3. Reference `.agent-docs/AGENTS.md` + the relevant `.agent-docs/context/*.md` file(s) in the task.md preamble so spawned agents know exactly what to read.

4. You can use the `wta` CLI to spawn and manage sub-agent sessions. Check your CLAUDE.md for the full orchestrator reference — it was just updated with the available commands.

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
# Custom project prompts (stored in ~/.worktrees/<repo>/.prompts/)
# ---------------------------------------------------------------------------
MAX_CUSTOM_PROMPTS=3

# Resolve the .prompts/ directory for the current repo
get_prompts_dir() {
    local pane_cwd
    pane_cwd=$(tmux display-message -p '#{pane_current_path}')

    local repo_path
    repo_path=$(cd "$pane_cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
    [ -z "$repo_path" ] && return 1

    local repo_name
    repo_name=$(get_repo_name "$repo_path")

    local base_path
    base_path=$(expand_tilde "${WORKTREE_PATH:-$HOME/.worktrees}")

    echo "$base_path/$repo_name/.prompts"
}

# List custom prompt files (sorted by name)
list_custom_prompts() {
    local prompts_dir="$1"
    [ -d "$prompts_dir" ] || return 0
    find "$prompts_dir" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort
}

# Read title (first line) from a prompt file
get_prompt_title() {
    head -1 "$1" 2>/dev/null | sed 's/^#* *//'
}

# Read body (everything after first line) from a prompt file
get_prompt_body() {
    tail -n +2 "$1" 2>/dev/null
}

# Send a custom prompt to the agent
run_custom_prompt() {
    local prompt_file="$1"
    local body
    body=$(get_prompt_body "$prompt_file")
    if [ -z "$body" ]; then
        log_warn "Prompt file is empty"
        return 1
    fi
    local title
    title=$(get_prompt_title "$prompt_file")
    send_prompt_to_agent "$body" "Custom prompt sent: $title"
}

# Add a new custom prompt via $EDITOR/vim
custom_prompt_add() {
    local prompts_dir="$1"

    local count
    count=$(list_custom_prompts "$prompts_dir" | wc -l | tr -d ' ')
    if [ "$count" -ge "$MAX_CUSTOM_PROMPTS" ]; then
        log_error "Maximum $MAX_CUSTOM_PROMPTS custom prompts reached. Remove one first."
        sleep 1.5
        return 1
    fi

    # Ask for a short name
    local name
    name=$(prompt "Prompt name (short, no spaces)" "")
    [ -z "$name" ] && return 1
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')

    local filepath="$prompts_dir/${name}.md"
    if [ -f "$filepath" ]; then
        log_error "Prompt '$name' already exists. Use edit instead."
        sleep 1.5
        return 1
    fi

    mkdir -p "$prompts_dir"

    # Seed with a template
    cat > "$filepath" <<'TEMPLATE'
# Prompt Title Here
Replace this with your prompt text.
The first line (after #) is the menu title.
Everything below is sent to the agent.
TEMPLATE

    local editor="${EDITOR:-vim}"
    "$editor" "$filepath" </dev/tty >/dev/tty 2>/dev/tty

    # Remove if user left the template or emptied the file
    if [ ! -s "$filepath" ] || head -1 "$filepath" | grep -q '^# Prompt Title Here$'; then
        rm -f "$filepath"
        log_info "Cancelled — prompt not saved"
        sleep 1
        return 1
    fi

    log_success "Custom prompt '$name' saved"
    sleep 1
}

# Edit an existing custom prompt
custom_prompt_edit() {
    local prompts_dir="$1"

    local files
    files=$(list_custom_prompts "$prompts_dir")
    [ -z "$files" ] && { log_warn "No custom prompts to edit"; sleep 1; return 1; }

    # Build fzf list: "filename — title"
    local menu=""
    while IFS= read -r f; do
        local title
        title=$(get_prompt_title "$f")
        local base
        base=$(basename "$f" .md)
        menu+="${base} — ${title}"$'\n'
    done <<< "$files"

    local pick
    pick=$(echo -n "$menu" | fzf \
        --ansi \
        --header="Select prompt to edit" \
        --layout=reverse \
        --height=100% \
        --no-preview \
        --bind='esc:cancel')
    [ -z "$pick" ] && return 0

    local name="${pick%% — *}"
    local filepath="$prompts_dir/${name}.md"

    local editor="${EDITOR:-vim}"
    "$editor" "$filepath" </dev/tty >/dev/tty 2>/dev/tty

    log_success "Prompt '$name' updated"
    sleep 1
}

# Remove a custom prompt
custom_prompt_remove() {
    local prompts_dir="$1"

    local files
    files=$(list_custom_prompts "$prompts_dir")
    [ -z "$files" ] && { log_warn "No custom prompts to remove"; sleep 1; return 1; }

    local menu=""
    while IFS= read -r f; do
        local title
        title=$(get_prompt_title "$f")
        local base
        base=$(basename "$f" .md)
        menu+="${base} — ${title}"$'\n'
    done <<< "$files"

    local pick
    pick=$(echo -n "$menu" | fzf \
        --ansi \
        --header="Select prompt to remove" \
        --layout=reverse \
        --height=100% \
        --no-preview \
        --bind='esc:cancel')
    [ -z "$pick" ] && return 0

    local name="${pick%% — *}"
    local filepath="$prompts_dir/${name}.md"

    rm -f "$filepath"
    log_success "Prompt '$name' removed"
    sleep 1
}

# Sub-menu for managing custom prompts
manage_custom_prompts() {
    local prompts_dir
    prompts_dir=$(get_prompts_dir) || { log_error "Not in a git repository"; exit 1; }

    local action
    action=$(printf "Add new prompt\nEdit prompt\nRemove prompt" | fzf \
        --ansi \
        --header="Manage Custom Prompts" \
        --layout=reverse \
        --height=100% \
        --no-preview \
        --bind='esc:cancel')
    [ -z "$action" ] && return 0

    case "$action" in
        "Add new prompt")    custom_prompt_add "$prompts_dir" ;;
        "Edit prompt")       custom_prompt_edit "$prompts_dir" ;;
        "Remove prompt")     custom_prompt_remove "$prompts_dir" ;;
    esac
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
main() {
    # Build menu: custom prompts first, then separator, then built-ins
    local prompts_dir
    prompts_dir=$(get_prompts_dir 2>/dev/null)

    local custom_entries=""
    if [ -n "$prompts_dir" ] && [ -d "$prompts_dir" ]; then
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            local title
            title=$(get_prompt_title "$f")
            [ -n "$title" ] && custom_entries+="★ ${title}"$'\n'
        done < <(list_custom_prompts "$prompts_dir")
    fi

    local menu=""
    if [ -n "$custom_entries" ]; then
        menu+="${custom_entries}"
        menu+="──────────────────────────"$'\n'
    fi
    menu+="Start sub-agent task
Generate task.md
Merge completed tasks
Update constraints
Simplify project
──────────────────────────
Manage custom prompts"

    local preview_script="$SCRIPT_DIR/prompt-preview.sh"

    local action
    action=$(echo -n "$menu" | fzf \
        --ansi \
        --header="$(printf 'Task Prompts — select an action\n\nEnter: run  Esc: cancel  Tab: toggle preview')" \
        --layout=reverse \
        --height=100% \
        --preview="bash '$preview_script' {} '${prompts_dir:-}'" \
        --preview-window=right:60%:wrap \
        --bind='tab:toggle-preview' \
        --bind='esc:cancel')

    if [ -z "$action" ] || [[ "$action" == ──* ]]; then
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
        "Manage custom prompts")
            manage_custom_prompts
            ;;
        ★*)
            # Custom prompt — match title back to file
            local selected_title="${action#★ }"
            if [ -n "$prompts_dir" ]; then
                while IFS= read -r f; do
                    [ -z "$f" ] && continue
                    local title
                    title=$(get_prompt_title "$f")
                    if [ "$title" = "$selected_title" ]; then
                        run_custom_prompt "$f"
                        break
                    fi
                done < <(list_custom_prompts "$prompts_dir")
            fi
            ;;
    esac
}

main "$@"
