#!/usr/bin/env bash

# Shared utilities for tmux-worktree-agent

# Get plugin directory
PLUGIN_DIR="${WORKTREE_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
METADATA_FILE="$PLUGIN_DIR/.worktree-sessions.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ${NC} $*"
}

log_success() {
    echo -e "${GREEN}✓${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $*"
}

log_error() {
    echo -e "${RED}✗${NC} $*"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Find agent PID in pane's process tree
# Handles native binaries (bash → claude) and node/bun-wrapped agents (bash → node → codex)
find_agent_pid() {
    local pane_pid="$1"
    local agent_process="$2"
    local pid

    # Direct child (native binaries like claude)
    pid=$(pgrep -P "$pane_pid" -x "$agent_process" 2>/dev/null | head -1)
    if [ -n "$pid" ]; then
        echo "$pid"
        return 0
    fi

    # Grandchild (node/bun-wrapped agents like codex, gemini)
    local child_pids
    child_pids=$(pgrep -P "$pane_pid" 2>/dev/null)
    for cpid in $child_pids; do
        pid=$(pgrep -P "$cpid" -x "$agent_process" 2>/dev/null | head -1)
        if [ -n "$pid" ]; then
            echo "$pid"
            return 0
        fi
    done

    return 1
}

# Check required dependencies
check_dependencies() {
    local missing=()

    if ! command_exists git; then
        missing+=("git")
    fi

    if ! command_exists jq; then
        missing+=("jq")
    fi

    if ! command_exists fzf; then
        missing+=("fzf")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_info "Please install: ${missing[*]}"
        return 1
    fi

    return 0
}

# Get git repository name
get_repo_name() {
    local repo_path="$1"

    # Try to get from remote URL
    local remote_url
    remote_url=$(cd "$repo_path" && git remote get-url origin 2>/dev/null)

    if [ -n "$remote_url" ]; then
        # Extract repo name from URL
        basename "$remote_url" .git
    else
        # Use directory name
        basename "$repo_path"
    fi
}

# Check if in git repository
is_git_repo() {
    git rev-parse --show-toplevel >/dev/null 2>&1
}

# Get git repository root
get_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

# Get current branch
get_current_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null
}

# Get the default/base branch for a repo (main, master, trunk, etc.)
get_default_branch() {
    local repo_path="${1:-.}"

    # Most reliable: what the remote considers its HEAD
    local branch
    branch=$(cd "$repo_path" && git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
    if [ -n "$branch" ]; then
        echo "$branch"
        return 0
    fi

    # Fallback: user's global git config default
    branch=$(git config --global init.defaultBranch 2>/dev/null)
    if [ -n "$branch" ]; then
        echo "$branch"
        return 0
    fi

    echo "main"
}

# Sanitize name for use in paths and session names
sanitize_name() {
    echo "$1" | tr '/' '-' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
}

# Generate session name
generate_session_name() {
    local repo="$1"
    local topic="$2"
    echo "${repo}-${topic}"
}

# Check if tmux session exists
session_exists() {
    tmux has-session -t "$1" 2>/dev/null
}

# Read-based fallback for prompt (used when gum fails or is unavailable)
_prompt_read() {
    local message="$1"
    local default="${2:-}"

    echo -n "$message" >&2
    if [ -n "$default" ]; then
        echo -n " [$default]" >&2
    fi
    echo -n ": " >&2
    local response
    if [ -r /dev/tty ]; then
        read -r response </dev/tty
    else
        read -r response
    fi
    echo "${response:-$default}"
}

# Read-based fallback for confirm
_confirm_read() {
    local message="$1"

    echo -n "$message [y/N]: " >&2
    local response
    if [ -r /dev/tty ]; then
        read -r response </dev/tty
    else
        read -r response
    fi
    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# Read-based fallback for choose
_choose_read() {
    local prompt_msg="$1"
    shift
    local options=("$@")

    echo "$prompt_msg" >&2
    select opt in "${options[@]}"; do
        if [ -n "$opt" ]; then
            echo "$opt"
            break
        fi
    done < /dev/tty
}

# Check if gum can be used (installed AND has a working TTY)
# Note: [ -r /dev/tty ] checks permissions, not whether the device works.
# We must actually try opening it to detect "Device not configured" errors.
# The subshell suppresses bash's own redirect error message.
_gum_available() {
    command_exists gum && (echo -n "" > /dev/tty) 2>/dev/null
}

# Prompt user (with fallback from gum to read)
prompt() {
    local message="$1"
    local default="${2:-}"

    if _gum_available; then
        gum input --placeholder "$message" --value "$default"
    else
        _prompt_read "$message" "$default"
    fi
}

# Confirm action
confirm() {
    local message="$1"
    local default="${2:-n}"

    if _gum_available; then
        gum confirm "$message"
        return $?
    else
        _confirm_read "$message"
    fi
}

# Choose from list
choose() {
    local prompt_msg="$1"
    shift
    local options=("$@")

    if _gum_available; then
        gum choose --header "$prompt_msg" "${options[@]}"
    else
        _choose_read "$prompt_msg" "${options[@]}"
    fi
}

# Select branch with arrow key navigation
select_branch() {
    local repo_path="$1"
    local allow_new="${2:-true}"

    # Fallback to simple prompt if fzf not available
    if ! command_exists fzf; then
        log_warn "fzf not available, using simple input"
        prompt "Branch name"
        return
    fi

    # Get branches sorted by recent activity
    local branches
    branches=$(cd "$repo_path" && \
        git for-each-ref --sort=-committerdate refs/heads/ \
            --format='%(refname:short)|%(committerdate:relative)|%(subject)' 2>/dev/null)

    if [ -z "$branches" ]; then
        log_warn "No branches found in repository"
        prompt "Branch name"
        return
    fi

    # Format branches for display (align columns)
    local formatted_branches
    formatted_branches=$(echo "$branches" | awk -F'|' '{
        branch = $1
        date = $2
        subject = substr($3, 1, 50)
        printf "%-30s  %-20s  %s\n", branch, date, subject
    }')

    # Use fzf with preview
    local selected
    selected=$(echo "$formatted_branches" | fzf \
        --ansi \
        --height=100% \
        --header="↑↓ Navigate | Enter: Select | Type: Filter/New Branch | Esc: Cancel" \
        --layout=reverse \
        --preview="cd '$repo_path' && git log --oneline --graph --color=always {1} 2>/dev/null | head -20" \
        --preview-window=right:60%:wrap \
        --bind='esc:cancel' \
        --print-query \
        --delimiter=' ' \
        --nth=1 \
        --with-nth=1,2,3)

    # fzf with --print-query outputs query on first line, selection on second
    # If user types and presses Enter without selecting, only query is returned
    # If user selects a branch, both query and selection are returned
    local query selection
    if [ -n "$selected" ]; then
        query=$(echo "$selected" | head -1)
        selection=$(echo "$selected" | tail -1)

        # If selection is empty or same as query, user typed a branch name
        if [ -z "$selection" ] || [ "$query" = "$selection" ]; then
            echo "$query"
        else
            # Extract branch name (first column)
            echo "$selection" | awk '{print $1}'
        fi
    else
        # User cancelled (Esc)
        return 1
    fi
}

# Select agent with fzf picker
select_agent() {
    local agent_list="${WORKTREE_AGENT_LIST:-claude}"
    local default_agent="${WORKTREE_AGENT_CMD:-claude}"

    # Parse comma-separated list into array
    local agents=()
    IFS=',' read -ra agents <<< "$agent_list"

    # Filter to only installed agents
    local available=()
    for agent in "${agents[@]}"; do
        agent=$(echo "$agent" | xargs)  # trim whitespace
        if command_exists "$agent"; then
            available+=("$agent")
        fi
    done

    # No agents available
    if [ ${#available[@]} -eq 0 ]; then
        log_warn "No agents from list are installed"
        return 1
    fi

    # Single agent — auto-select, skip fzf
    if [ ${#available[@]} -eq 1 ]; then
        echo "${available[0]}"
        return 0
    fi

    # Build display list with default tag
    local display_list=""
    for agent in "${available[@]}"; do
        if [ "$agent" = "$default_agent" ]; then
            display_list+="${agent} (default)"$'\n'
        else
            display_list+="${agent}"$'\n'
        fi
    done
    # Remove trailing newline
    display_list="${display_list%$'\n'}"

    # Use fzf to pick
    local selected
    selected=$(echo "$display_list" | fzf \
        --ansi \
        --header="Select agent | Enter: Select | Esc: Cancel" \
        --layout=reverse \
        --height=100% \
        --no-info \
        --bind='esc:cancel')

    if [ -z "$selected" ]; then
        return 1
    fi

    # Strip "(default)" tag if present
    echo "$selected" | awk '{print $1}'
}

# Expand tilde in path
expand_tilde() {
    local path="$1"
    echo "${path/#\~/$HOME}"
}

# Get worktree path
get_worktree_path() {
    local repo="$1"
    local topic="$2"
    local base_path
    base_path=$(expand_tilde "${WORKTREE_PATH:-$HOME/.worktrees}")

    echo "$base_path/$repo/$topic"
}

# Generate window name as "agent:branch" from session metadata
# Usage: generate_window_name [session_name] [agent_override] [branch_override]
# Falls back to "shell" if no metadata and no overrides
generate_window_name() {
    local session_name="${1:-$(tmux display-message -p '#{session_name}')}"
    local agent_override="$2"
    local branch_override="$3"

    local branch agent_label

    # Use overrides first, then metadata, then fallback
    if [ -n "$branch_override" ]; then
        branch="$branch_override"
        agent_label="${agent_override%% *}"
        agent_label="${agent_label:-sh}"
        echo "${agent_label}:${branch}"
    elif session_in_metadata "$session_name"; then
        branch=$(get_session_field "$session_name" "branch")
        if [ -n "$agent_override" ]; then
            agent_label="${agent_override%% *}"
        else
            agent_label=$(get_session_field "$session_name" "agent_cmd")
            agent_label="${agent_label%% *}"
        fi
        agent_label="${agent_label:-sh}"
        echo "${agent_label}:${branch}"
    else
        echo "shell"
    fi
}

# Rename a window using session metadata
# Usage: rename_window_from_metadata <window_target> [agent_override] [branch_override]
rename_window_from_metadata() {
    local window_target="$1"
    local agent_override="$2"
    local branch_override="$3"
    local session_name="${window_target%%:*}"
    local name
    name=$(generate_window_name "$session_name" "$agent_override" "$branch_override")
    tmux rename-window -t "$window_target" "$name"
}

# Create tmux session
create_tmux_session() {
    local session_name="$1"
    local worktree_path="$2"
    local launch_agent="${3:-true}"
    local agent_cmd="${4:-}"
    local topic="${5:-}"
    local branch="${6:-}"

    # Create detached session
    tmux new-session -d -s "$session_name" -c "$worktree_path"

    # Set window name to agent:branch (e.g. claude:wt/bug-fix)
    local base_idx
    base_idx=$(tmux show-option -gv base-index 2>/dev/null || echo 0)
    if [ -n "$topic" ]; then
        rename_window_from_metadata "$session_name:${base_idx}" "$agent_cmd" "$branch"
    fi

    # Launch agent if requested
    if [ "$launch_agent" = "true" ] && [ -n "$agent_cmd" ]; then
        if command_exists "${agent_cmd%% *}"; then
            tmux send-keys -t "$session_name" "$agent_cmd" C-m
        else
            log_warn "Agent command '$agent_cmd' not found"
        fi
    fi
}

# Switch to session
switch_to_session() {
    local session_name="$1"

    if [ -n "$TMUX" ]; then
        tmux switch-client -t "$session_name"
    else
        tmux attach-session -t "$session_name"
    fi
}

# Get current session name
# CALLER_SESSION is set by keybindings, but display-popup may not expand
# tmux formats in the shell command, leaving the literal '#{session_name}'.
# Guard against that and fall back to display-message which works in popups.
get_current_session() {
    if [ -n "${CALLER_SESSION:-}" ] && [[ "$CALLER_SESSION" != *'#{'* ]]; then
        echo "$CALLER_SESSION"
    else
        tmux display-message -p '#S'
    fi
}

# Map agent command to its config filename
# claude -> CLAUDE.md, codex -> AGENTS.md, gemini -> GEMINI.md, etc.
get_agent_config_filename() {
    local agent_cmd="$1"
    local agent_name="${agent_cmd%% *}"  # strip args

    case "$agent_name" in
        claude)   echo "CLAUDE.md" ;;
        codex)    echo "AGENTS.md" ;;
        gemini)   echo "GEMINI.md" ;;
        opencode) echo "AGENTS.md" ;;
        *)        echo "AGENTS.md" ;;  # AGENTS.md is the most widely supported fallback
    esac
}

# Write agent-specific config file into a worktree with task context and broadcast requirement
write_agent_config() {
    local worktree_path="$1"
    local agent_cmd="$2"
    local task_id="$3"
    local task_filename="$4"

    local config_file
    config_file=$(get_agent_config_filename "$agent_cmd")

    cat > "$worktree_path/$config_file" <<AGENTCFG
# Task: ${task_id}

Read \`${task_filename}.md\` for your task description and acceptance criteria.
Read \`.shared/context.md\` for project context.
Read \`.shared/broadcasts/\` for updates from other agents working on parallel tasks.
If \`.agent-docs/AGENTS.md\` exists, read it for module boundaries and routing, then read the relevant \`.agent-docs/context/*.md\` file for your domain.

## REQUIRED: Write Broadcast on Completion

When you finish your task, you MUST write \`.shared/broadcasts/${task_id}.md\` before stopping:

\`\`\`markdown
# ${task_id} — Completed

## Changes Made
- <what you changed, with file paths>

## Impact on Other Tasks
- <how your changes affect other tasks, or "None — fully independent">

## Files Modified
- <list of files changed>
\`\`\`

This broadcast is required for the merge orchestrator to review and merge your work.
Do NOT modify any other file in \`.shared/\`.

## Important: Scaffolding Files

The following files are plugin scaffolding injected into your worktree — they are NOT part of your task:
- This file (\`${config_file}\`) — agent instructions, do NOT commit
- \`${task_filename}.md\` — your task description, do NOT commit
- \`.shared/\` — symlink to shared context directory, do NOT commit
- \`wt-*.md\` — any task file in the worktree root, do NOT commit

Do NOT \`git add\` these files. Only commit files related to your actual task fix.
AGENTCFG
}

# Inject or update orchestrator awareness into a project's CLAUDE.md
# Called when "Generate task.md" is triggered — gives the main agent
# knowledge of the wta CLI so it can drive the plugin.
inject_orchestrator_config() {
    local repo_path="$1"

    local claude_md="$repo_path/CLAUDE.md"
    local wta_path="$PLUGIN_DIR/scripts/wta.sh"
    local start_marker="<!-- wta:orchestrator:start -->"
    local end_marker="<!-- wta:orchestrator:end -->"

    # Write section to a temp file (avoids heredoc quoting issues in bash)
    local section_file
    section_file=$(mktemp)
    cat > "$section_file" <<WTA_EOF
${start_marker}

## Orchestrator — tmux-worktree-agent

You are the **orchestrator agent**. You sit in the main repo and coordinate task agents
working in parallel across git worktrees. A tmux plugin (\`tmux-worktree-agent\`) manages
sessions, worktrees, and metadata — you interact with it through the \`wta\` CLI below.

### Two kinds of sub-agents — do not confuse them

| | **wta spawn** (worktree agent) | **Your built-in sub-agent** (e.g. Agent tool) |
|---|---|---|
| **Where** | Separate tmux session, separate git worktree, separate branch | Inside YOUR session, your worktree, your branch |
| **Isolation** | Full filesystem isolation — can modify files without conflicts | Shares your working directory — concurrent edits risk conflicts |
| **When to use** | Tasks that modify files and need their own branch (from task.md) | Research, analysis, reading code, planning — anything read-only within this session |
| **Lifecycle** | Persists after you stop — runs independently until done | Lives and dies with your conversation turn |

**Rule**: Use \`wta spawn\` for any task that writes/modifies files. Use your built-in sub-agents
only for read-only work within this session (exploring code, searching, analyzing).
Never use your built-in sub-agents to do the work described in task.md — that work
must go through \`wta spawn\` so each task gets its own branch and worktree.

### wta CLI

Run commands with: \`bash ${wta_path} <command> [args...]\`

**Read-only** (use freely):

| Command | Description |
|---|---|
| \`wta status [repo]\` | All sessions with agent state (active/prompt/off/dead) |
| \`wta broadcasts <repo>\` | Read completion broadcasts from \`.shared/broadcasts/\` |
| \`wta capture <session>\` | Last 40 lines of a session's terminal output |
| \`wta topology <task.md>\` | Task dependency graph with live completion state |
| \`wta diff <session>\` | Git diff of session's branch vs its base branch |

**Mutating** (confirm with the user before running):

| Command | Description |
|---|---|
| \`wta spawn <task.md> <task-id>\` | Create worktree + tmux session + start agent for a task |
| \`wta send <session> <text>\` | Paste text into an agent's terminal and hit Enter |
| \`wta kill <session>\` | Full cleanup: kill session, remove worktree, delete branch + metadata |

### Workflow

1. **Generate task.md** — break work into non-overlapping tasks (you may have just done this)
2. **Spawn tasks** — \`wta spawn task.md TASK-xxx\` for each task (confirm with user first)
3. **Monitor** — \`wta status\` and \`wta capture <session>\` to watch progress
4. **Read broadcasts** — \`wta broadcasts <repo>\` to see completed work
5. **Guide stuck agents** — \`wta send <session> "<instruction>"\` if an agent needs help
6. **Review & merge** — \`wta diff <session>\` to review, then merge branches in dependency order
7. **Clean up** — \`wta kill <session>\` for finished/failed sessions

### Rules

- **Never modify \`.worktree-sessions.json\` directly** — always use \`wta\` commands
- **Confirm with the user** before running any mutating command (spawn, send, kill)
- **Merge in dependency order** — if TASK-B depends on TASK-A, merge A first
- **Check broadcasts before merging** — verify the broadcast matches the actual diff
- Task agents write their results to \`.shared/broadcasts/TASK-<id>.md\`
- Task agents read shared context from \`.shared/context.md\` (seeded from task.md preamble)
- Branch convention: each task gets \`wt/<sanitized-task-id>\`
- Task agents have NO knowledge of this plugin or \`wta\` — they only know their task file,
  \`.shared/context.md\`, and \`.shared/broadcasts/\`. Do not assume they can run wta commands.

${end_marker}

<!-- wta:docs-pyramid:start -->

## Documentation Pyramid — Maintain This Structure

Project documentation follows a **progressive disclosure pyramid**. Principle: **exact context at the right time** — agents read only what they need for the task at hand.

\`\`\`
Layer 1: CLAUDE.md                      (~120 lines, always auto-loaded)
  What is this project? How to build? Where to look?

Layer 2: .agent-docs/AGENTS.md          (~60 lines, read before writing code)
  Module boundaries. "Before touching X, read Y" routing table.

Layer 3: .agent-docs/context/*.md       (~60-100 lines each, read ONLY the relevant one)
  One file per domain: backend, frontend, database, etc.

Layer 4: .agent-docs/{architecture,design,guides}/  (full reference, deep dives only)
  Detailed designs, worked examples, full API docs.
\`\`\`

### Maintenance rules

1. **Never dump all context into one file.** If a doc exceeds ~100 lines, it belongs in Layer 3 or 4.
2. **Layer 1-2 are routing layers** — they point to information, they don't contain it. Keep them thin.
3. **Layer 3 context files are domain-scoped** — one file per domain. New domain = new file, don't bloat existing ones.
4. **Layer 4 is reference** — detailed designs, worked examples, full API docs. Read only for deep feature work.
5. **When updating architecture**, update \`.agent-docs/context/*.md\` first (what agents consume), then Layer 4 if needed.
6. **When creating task.md**, reference \`.agent-docs/AGENTS.md\` + specific \`.agent-docs/context/*.md\` files in the preamble.

<!-- wta:docs-pyramid:end -->
WTA_EOF

    if [ -f "$claude_md" ]; then
        if grep -q "$start_marker" "$claude_md"; then
            # Replace existing section between markers
            local before_file after_file tmpfile
            before_file=$(mktemp)
            after_file=$(mktemp)
            tmpfile=$(mktemp)
            awk "/$start_marker/{exit} {print}" "$claude_md" > "$before_file"
            awk "found{print} /$end_marker/{found=1}" "$claude_md" > "$after_file"
            cat "$before_file" "$section_file" "$after_file" > "$tmpfile"
            mv "$tmpfile" "$claude_md"
            rm -f "$before_file" "$after_file"
        else
            # Append to existing file
            echo "" >> "$claude_md"
            cat "$section_file" >> "$claude_md"
        fi
    else
        # Create new file
        cp "$section_file" "$claude_md"
    fi

    rm -f "$section_file"
}

# Set up .shared/ directory and symlink for a worktree
# Creates ~/.worktrees/<repo>/.shared/broadcasts/ if needed, symlinks into worktree
setup_shared_dir() {
    local worktree_path="$1"
    local shared_dir
    shared_dir="$(dirname "$worktree_path")/.shared"
    mkdir -p "$shared_dir/broadcasts"
    # Relative symlink so it works if ~/.worktrees is moved
    ln -sfn ../.shared "$worktree_path/.shared"
}

# Create a git worktree for a branch
# Returns 0 on success, 1 on failure, 2 if worktree already exists and is valid
create_worktree_for_branch() {
    local repo_path="$1"
    local worktree_path="$2"
    local branch_name="$3"
    local is_new_branch="${4:-true}"

    # Check if worktree directory already exists
    if [ -d "$worktree_path" ]; then
        if cd "$worktree_path" && git rev-parse --git-dir >/dev/null 2>&1; then
            log_info "Valid worktree already exists: $worktree_path"
            setup_shared_dir "$worktree_path"
            return 2
        else
            log_error "Directory exists but is not a git worktree: $worktree_path"
            return 1
        fi
    fi

    # Create parent directory
    mkdir -p "$(dirname "$worktree_path")"

    log_info "Creating worktree at: $worktree_path"

    cd "$repo_path" || return 1

    # Clean up stale worktree references (e.g. directory was deleted without git worktree remove)
    git worktree prune 2>/dev/null

    if [ "$is_new_branch" = "true" ]; then
        # Try creating new branch; if it already exists, reuse it
        if ! git worktree add "$worktree_path" -b "$branch_name" 2>/dev/null; then
            if git rev-parse --verify "$branch_name" >/dev/null 2>&1; then
                log_info "Branch '$branch_name' already exists, reusing"
                if ! git worktree add "$worktree_path" "$branch_name" 2>&1; then
                    log_error "Failed to create worktree for existing branch '$branch_name'"
                    return 1
                fi
            else
                log_error "Failed to create worktree with new branch '$branch_name'"
                return 1
            fi
        fi
    else
        # Check if branch is already checked out in another worktree
        if git worktree list | grep -q "\[$branch_name\]"; then
            log_error "Branch '$branch_name' is already checked out in another worktree"
            return 1
        fi

        if ! git worktree add "$worktree_path" "$branch_name" 2>&1; then
            log_error "Failed to create worktree for branch '$branch_name'"
            return 1
        fi
    fi

    log_success "Worktree created"
    setup_shared_dir "$worktree_path"
    return 0
}

# Spawn a tmux session for a worktree with metadata and agent
# Returns 0 on success, 1 on failure
spawn_session_for_worktree() {
    local session_name="$1"
    local repo_name="$2"
    local topic="$3"
    local branch_name="$4"
    local worktree_path="$5"
    local repo_path="$6"
    local description="${7:-}"
    local auto_switch="${8:-true}"
    local parent_branch="${9:-}"
    local parent_session="${10:-}"

    # Auto-detect parent branch if not provided
    if [ -z "$parent_branch" ] && [ -d "$repo_path" ]; then
        parent_branch=$(cd "$repo_path" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
    fi

    # Auto-detect parent session if not provided
    if [ -z "$parent_session" ] && [ -n "$TMUX" ]; then
        parent_session=$(get_current_session 2>/dev/null || true)
    fi

    # Determine if we should launch agent
    local auto_agent="${WORKTREE_AUTO_AGENT:-on}"
    local launch_agent=false
    local agent_cmd=""

    case "$auto_agent" in
        on)
            agent_cmd="${WORKTREE_AGENT_CMD:-claude}"
            if command_exists "${agent_cmd%% *}"; then
                launch_agent=true
            else
                log_warn "Agent '$agent_cmd' not found"
            fi
            ;;
        prompt)
            if agent_cmd=$(select_agent) && [ -n "$agent_cmd" ]; then
                launch_agent=true
            fi
            ;;
        off)
            launch_agent=false
            agent_cmd=""
            ;;
    esac

    # Create tmux session
    log_info "Creating tmux session: $session_name"
    create_tmux_session "$session_name" "$worktree_path" "$launch_agent" "$agent_cmd" "$topic" "$branch_name"

    # Save metadata
    local agent_available=false
    if [ -n "$agent_cmd" ]; then
        agent_available=true
    fi

    # Source metadata.sh if save_session not available
    if ! type save_session >/dev/null 2>&1; then
        source "$PLUGIN_DIR/lib/metadata.sh"
    fi

    save_session "$session_name" "$repo_name" "$topic" "$branch_name" \
        "$worktree_path" "$repo_path" "$agent_available" "$description" "$agent_cmd" \
        "$parent_branch" "$parent_session"

    log_success "Session created: $session_name"

    # Switch to session if requested
    if [ "$auto_switch" = "true" ]; then
        switch_to_session "$session_name"
    fi

    return 0
}
