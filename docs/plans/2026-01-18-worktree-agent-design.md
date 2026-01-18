# tmux-worktree-agent Design Document

**Date**: 2026-01-18
**Version**: 1.0
**Status**: Design Complete

## Overview

A tmux plugin that optimizes workflows for managing multiple AI coding agent instances across git worktrees. Enables human multithreading by making it easy to work on different topics/branches simultaneously with isolated tmux sessions.

## Goals

- Make working with multiple AI agent instances (Claude Code, Gemini, OpenCode, Codex) easy and efficient
- Integrate git worktrees with tmux sessions seamlessly
- Enable human multithreading: work on different topics in parallel without context switching overhead
- Agent-agnostic design: works with any AI coding CLI tool
- Simple setup: install via TPM like any other tmux plugin

## Architecture

### Plugin Structure

```
tmux-worktree-agent/
├── worktree-agent.tmux          # Main plugin file (TPM entry point)
├── scripts/
│   ├── create-worktree.sh       # Create worktree + session
│   ├── browse-sessions.sh       # Fuzzy finder browser
│   ├── kill-worktree.sh         # Clean up worktree + session
│   ├── session-info.sh          # Get current session metadata
│   └── utils.sh                 # Shared utilities
├── lib/
│   └── metadata.sh              # JSON metadata management
├── docs/
│   └── plans/
│       └── 2026-01-18-worktree-agent-design.md
└── README.md
```

### Components

**1. Worktree Session Manager** (`scripts/create-worktree.sh`)
- Detects current git repository
- Prompts for branch name and topic
- Creates worktree at `~/.worktrees/<repo>/<topic>`
- Creates tmux session named `<repo>-<topic>`
- Launches configured AI agent
- Saves metadata

**2. Session Browser** (`scripts/browse-sessions.sh`)
- fzf-based interface showing all worktree sessions
- Displays session name, branch, and worktree path
- Fuzzy search across all fields
- Preview pane with git status and session details
- Quick navigation and deletion

**3. Metadata Manager** (`lib/metadata.sh`)
- Stores session data in `~/.tmux/plugins/tmux-worktree-agent/.worktree-sessions.json`
- Tracks repo, branch, worktree path, creation time
- Handles orphaned sessions and worktrees
- Auto-cleanup utilities

## Workflows

### Creating a New Worktree Session

**Trigger**: `prefix + C-w` (full create) or `prefix + W` (quick create from current branch)

**Full Create Flow**:
1. Detect git repo via `git rev-parse --show-toplevel`
2. If not a git repo: Prompt "Initialize git here? [y/N]"
3. Prompt: "Branch name?" (with autocomplete from `git branch`)
4. Prompt: "Topic/description?"
5. Create worktree: `git worktree add ~/.worktrees/<repo>/<topic> -b <branch>`
6. Create tmux session: `<repo>-<topic>`
7. Launch agent (configurable command, default: `claude`)
8. Save metadata
9. Attach to session

**Quick Create Flow** (when on existing branch):
1. Auto-detect current branch
2. Prompt: "Topic name for <branch>?"
3. Proceed with steps 5-9

### Browsing & Switching Sessions

**Trigger**: `prefix + w`

**Interface**:
```
┌─ Worktree Sessions (3 active) ─────────────────────────────┐
│ ● raptor-feature-auth  feature/auth    ~/.worktrees/...    │
│ ○ raptor-bugfix-api    bugfix/api      ~/.worktrees/...    │
│ ○ raptor-main          master          ~/localGit/raptor   │
└────────────────────────────────────────────────────────────┘
```

**Keybindings** (in fzf):
- `Enter` - Switch to session
- `Ctrl-d` - Delete session + worktree (with confirmation)
- `Ctrl-r` - Refresh list
- `Tab` - Toggle preview (git status, windows, processes)
- `Esc` - Cancel

**Search**: Fuzzy search across session name, branch name, worktree path

### Cleaning Up

**Trigger**: `prefix + K` (in worktree session)

**Flow**:
1. Confirm: "Kill session and remove worktree for <topic>? [y/N]"
2. Kill tmux session
3. Remove git worktree: `git worktree remove <path>`
4. Delete metadata entry
5. Switch to previous session

## Configuration

### Installation

Add to `~/.tmux.conf`:
```bash
set -g @plugin 'your-github-username/tmux-worktree-agent'

# Optional configuration
set -g @worktree-path '~/.worktrees'         # Worktree storage location
set -g @worktree-agent-cmd 'claude'          # Agent command (claude/gemini/opencode/codex)
set -g @worktree-auto-agent 'on'             # 'on', 'off', 'prompt'
set -g @worktree-browser-key 'w'             # Browser keybinding
set -g @worktree-create-key 'C-w'            # Create keybinding
set -g @worktree-quick-create-key 'W'        # Quick create keybinding
set -g @worktree-kill-key 'K'                # Kill keybinding
```

Install: `prefix + I` (TPM)

### Default Keybindings

- `prefix + w` - Browse/switch worktree sessions
- `prefix + C-w` - Create new worktree session (full)
- `prefix + W` - Quick create (auto-detect current branch)
- `prefix + K` - Kill current worktree + session
- `prefix + R` - Refresh metadata (rescan)

### Agent Configuration

**Agent-Agnostic Design**:
```bash
# Claude Code
set -g @worktree-agent-cmd 'claude'

# Gemini Code
set -g @worktree-agent-cmd 'gemini code'

# OpenCode
set -g @worktree-agent-cmd 'opencode'

# Codex
set -g @worktree-agent-cmd 'codex'

# No agent (manual workflow)
set -g @worktree-auto-agent 'off'
```

**Fallback Behavior**:
If agent command not found:
- Show: "Agent command '<cmd>' not found. Configure with: set -g @worktree-agent-cmd 'your-agent'"
- If `@worktree-auto-agent` is 'prompt': Ask "Launch anyway without agent?"
- If 'off': Create session without agent

## Data Model

### Metadata Schema

File: `~/.tmux/plugins/tmux-worktree-agent/.worktree-sessions.json`

```json
{
  "raptor-feature-auth": {
    "repo": "raptor",
    "topic": "feature-auth",
    "branch": "feature/auth",
    "worktree_path": "/Users/username/.worktrees/raptor/feature-auth",
    "main_repo_path": "/Users/username/localGit/raptor",
    "created_at": "2026-01-18T15:30:00Z",
    "agent_running": true
  }
}
```

### Repository Detection

1. Run `git rev-parse --show-toplevel` in current directory
2. If fails: Prompt "Initialize git here? [y/N]"
3. Extract repo name from `git remote get-url origin` or directory basename
4. Validate it's a git repository

### Worktree Location Strategy

**Centralized approach**: `~/.worktrees/<repo-name>/<topic>/`

- `<repo-name>` dynamically detected from current repository
- Keeps project directories clean
- Consistent location across all projects
- Example: `~/.worktrees/raptor/feature-auth/`

## Error Handling

### Duplicate Session Names
- Prompt: "[A]ttach / [R]ename / [C]ancel?"
- Attach: Switch to existing
- Rename: Prompt for new topic, retry
- Cancel: Abort

### Worktree Already Exists
- Check if tmux session exists
- If yes: Switch to it
- If no: Create new session, update metadata

### Not in Git Repository
- Prompt: "Initialize git here? [y/N]"
- If no: "Please run this from a git repository"

### Orphaned State Detection

Orphaned states occur when sessions and worktrees get out of sync. The plugin handles this gracefully:

**Detection Timing**:
- **Automatic**: When opening session browser (`prefix + w`)
- **On-demand**: Via reconcile command (`prefix + R`)
- **Lazy**: Not checked on every command to avoid performance overhead

**State 1: Worktree Deleted, Session Still Exists**

*How it happens*: User manually deletes worktree (e.g., `rm -rf ~/.worktrees/raptor/feature-auth`) but tmux session still running.

*Detection*:
```bash
# In browse-sessions.sh, for each metadata entry:
if tmux has-session -t "$session_name" 2>/dev/null; then
  if [ ! -d "$worktree_path" ]; then
    # Orphaned: session exists, worktree doesn't
    mark_orphaned=true
  fi
fi
```

*Browser Display*:
```
⚠ raptor-feature-auth  feature/auth  [WORKTREE DELETED]
```

*User Actions*:
- **Enter**: Shows warning "Worktree missing. [R]ecreate worktree / [K]ill session / [C]ancel?"
  - Recreate: `git worktree add` at same path, reuse session
  - Kill: Clean up session and metadata
  - Cancel: Do nothing
- **Ctrl-d**: Directly kill session and clean metadata

**State 2: Session Killed, Worktree Still Exists**

*How it happens*: User kills tmux session manually (`tmux kill-session`) or session crashes, but worktree directory remains.

*Detection*:
```bash
# Scan actual worktrees, compare with metadata
git worktree list --porcelain | parse_worktrees | while read worktree_path; do
  if ! metadata_has_session_for_path "$worktree_path"; then
    # Orphaned: worktree exists, no session tracked
  fi
done
```

*Browser Display*:
```
○ [no session]         feature/auth  ~/.worktrees/raptor/feature-auth
```

*User Actions*:
- **Enter**: Shows prompt "Create session for existing worktree? [Y/n]"
  - Yes: Create new tmux session, add metadata
  - No: Do nothing
- **Ctrl-d**: Shows "Delete worktree? [y/N]"
  - Yes: `git worktree remove`, clean up directory
  - No: Keep worktree

**State 3: Both Missing (Metadata Stale)**

*How it happens*: Both session and worktree cleaned up outside plugin.

*Detection*:
```bash
# In metadata, but neither session nor worktree exists
if ! tmux has-session -t "$session_name" && [ ! -d "$worktree_path" ]; then
  # Stale metadata
fi
```

*Handling*: Silently remove from metadata during reconcile.

**Reconcile Command** (`prefix + R`):

Scans and syncs all state:
1. Check each metadata entry:
   - Session exists? Worktree exists? → OK
   - Only session? → Mark orphaned (worktree deleted)
   - Only worktree? → Mark orphaned (no session)
   - Neither? → Remove from metadata
2. Scan git worktrees in `~/.worktrees/<repo>/`:
   - Has metadata? → OK
   - No metadata? → Offer to import as "[no session]" entry
3. Display summary:
   ```
   ✓ 3 sessions OK
   ⚠ 1 orphaned (worktree deleted)
   ⚠ 2 orphaned (no session)
   ✗ 1 stale metadata cleaned
   ```

**Performance Considerations**:
- Orphan checks only run when browsing or reconciling (not on every command)
- Use `tmux has-session` (fast) before filesystem checks
- Cache results for browser session (don't re-check on every keystroke)

## Dependencies

### Required
- tmux >= 3.0
- git >= 2.5
- fzf >= 0.20
- jq (JSON processing)

### Optional
- claude/gemini/opencode/codex (AI coding agents)
- bat (preview syntax highlighting, fallback to cat)
- gum (prettier prompts, fallback to read)

### Compatibility
- OS: Linux, macOS, WSL2
- Shell: bash, zsh
- tmux plugins: Compatible with TPM, catppuccin-tmux, tmux-fzf

## Status Bar Integration

When in worktree session, status bar shows:
- 🌳 icon indicating worktree session
- Current branch name
- Topic name

Example: `[raptor-feature-auth] 🌳 feature/auth | 2026-01-18 15:42`

## Testing Checklist

### Core Functionality
- [ ] Create worktree from main repo
- [ ] Create worktree with new branch
- [ ] Create worktree with existing branch
- [ ] Browser fuzzy search (name/branch/path)
- [ ] Delete via browser with confirmation
- [ ] Quick create from current branch
- [ ] Git init prompt for non-repos

### Edge Cases
- [ ] Worktree path with spaces
- [ ] Branch names with special characters
- [ ] Session name collision
- [ ] No git remote (use directory name)
- [ ] Agent command not found
- [ ] Metadata corruption recovery
- [ ] Orphaned session detection
- [ ] Multiple repositories

### Installation
- [ ] Fresh TPM install
- [ ] Configuration options apply correctly
- [ ] Keybindings don't conflict
- [ ] Clean uninstall

## Success Criteria

1. User can create isolated worktree sessions with single keybinding
2. Switching between multiple AI agent instances is fast and intuitive
3. Plugin works with any AI coding agent (Claude, Gemini, OpenCode, Codex)
4. Setup on new machine requires only adding plugin to tmux.conf
5. Worktrees and sessions stay in sync (no orphaned state)
6. Clear visual feedback about which worktree context user is in

## Future Enhancements

- Auto-cleanup stale worktrees after N days
- Session grouping by repository
- Workspace templates (auto-create multiple worktrees)
- Integration with tmux-resurrect for persistence
- Hook system for custom actions (pre/post create/delete)
