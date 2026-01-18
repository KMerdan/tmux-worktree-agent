# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

tmux-worktree-agent is a tmux plugin that optimizes workflows for managing multiple AI coding agent instances across git worktrees. It enables "human multithreading" by allowing users to work on different topics/branches simultaneously with isolated tmux sessions.

**Key Capabilities:**
- One-keybind workflow to create isolated worktree + tmux session
- Fuzzy search browser (fzf) for switching between sessions
- Automatic orphan detection for sessions/worktrees
- Agent-agnostic (works with Claude Code, Gemini, OpenCode, Codex, etc.)
- TPM (Tmux Plugin Manager) integration

## Architecture

### Entry Point & Configuration

**worktree-agent.tmux** - TPM plugin entry point
- Reads tmux options (@worktree-path, @worktree-agent-cmd, @worktree-auto-agent, etc.)
- Exports environment variables (WORKTREE_PATH, WORKTREE_AGENT_CMD, etc.)
- Sets up keybindings for all workflows
- Initializes metadata file (.worktree-sessions.json)
- Handles tilde expansion for paths

### Core Components

**lib/metadata.sh** - JSON metadata management library
- All session data persists in `.worktree-sessions.json` as structured JSON
- Each session stores: repo, topic, branch, worktree_path, main_repo_path, created_at, agent_running
- Functions: save_session(), get_session(), delete_session(), list_sessions(), find_session_by_path()
- Orphan detection: clean_orphaned_metadata(), get_orphaned_sessions(), get_orphaned_worktrees()
- Uses jq for all JSON operations

**scripts/utils.sh** - Shared utilities
- User interaction functions: prompt(), confirm(), choose()
- Git helpers: is_git_repo(), get_repo_root(), get_current_branch(), get_repo_name()
- Tmux helpers: session_exists(), create_tmux_session(), switch_to_session()
- Path sanitization: sanitize_name() (converts "/" to "-", lowercases, removes spaces)
- Fallback behavior: Uses gum if available, otherwise falls back to read/select
- Special handling: prompt() reads from /dev/tty to work in popup/split windows

### Workflows

**scripts/create-worktree.sh** - Create worktree + session workflow
- Two modes: full (prefix + C-w) and quick (prefix + W)
- Quick mode auto-detects current branch
- Validates branch existence, offers to create new branch
- Sanitizes topic names for filesystem safety
- Handles duplicate sessions (attach/rename/cancel)
- Creates parent directories before worktree creation
- Launches agent based on @worktree-auto-agent setting (on/off/prompt)
- Error handling: Manual error handling without set -e for better user feedback

**scripts/browse-sessions.sh** - fzf browser for sessions
- Status indicators: ● (active), ○ (worktree only), ⚠ (session only), ✗ (stale)
- Auto-cleanup of stale metadata on launch
- Preview pane shows: session info, active windows, git status
- Actions: Enter (switch), Ctrl-d (delete), Ctrl-r (refresh), Tab (toggle preview)
- Runs in tmux popup if tmux >= 3.2, otherwise splits

**scripts/kill-worktree.sh** - Cleanup workflow
- Removes session, git worktree, and metadata
- Switches to another session after cleanup
- Confirmation prompts

**scripts/reconcile.sh** - Orphan detection/repair
- Scans for orphaned sessions (session exists, worktree deleted)
- Scans for orphaned worktrees (worktree exists, no session)
- Offers fix options: recreate, delete, or cancel

**scripts/session-info.sh** - Status line integration
- Formats: icon, branch, topic, short, full, status-line
- Used for tmux status-right integration

### Directory Structure

```
~/.worktrees/<repo-name>/<topic>/  # Worktree storage
~/.tmux/plugins/tmux-worktree-agent/.worktree-sessions.json  # Metadata
```

## Development Workflow

### Testing Changes

Since this is a tmux plugin, testing requires tmux environment:

```bash
# 1. Make changes to scripts or plugin entry point

# 2. Reload tmux configuration
tmux source-file ~/.tmux.conf

# 3. Test interactively using keybindings:
# - prefix + C-w (create worktree)
# - prefix + w (browse sessions)
# - prefix + W (quick create)
# - prefix + K (kill worktree)
# - prefix + R (reconcile)
```

### Common Development Patterns

**When modifying prompt/input handling:**
- All user input must read from `/dev/tty` to work in popup/split windows
- Prompts should write to stderr, responses to stdout
- Test in both popup mode (tmux >= 3.2) and split-window fallback

**When modifying metadata:**
- Use jq for all JSON operations
- Always call init_metadata() before writing
- Use atomic file operations (write to .tmp, then mv)
- Source lib/metadata.sh from all scripts that need it

**When modifying git operations:**
- Always cd to repo_path before git commands
- Check for worktree conflicts (branch already checked out)
- Handle both new branch creation and existing branch checkout
- Show git errors to users for debugging

**When modifying tmux operations:**
- Use display-popup directly in keybindings (not run-shell wrappers)
- Provide fallback to split-window for older tmux versions
- Use -E flag to close popup after execution
- Set working directory with -c flag when creating sessions

### Path Handling

- All paths support tilde expansion via expand_tilde() function
- Worktree base path defaults to ~/.worktrees
- Session names are sanitized: repo-topic format
- Topic names: lowercase, "/" → "-", spaces removed

### Error Handling Philosophy

- create-worktree.sh: Manual error handling (no set -e) for better user experience
- Other scripts: Use set -e for fail-fast behavior
- Always show git errors to users
- Provide actionable error messages
- Offer recovery options (retry, cancel, recreate)

### Agent Integration

- Agent command configurable via @worktree-agent-cmd
- Auto-launch behavior: on (default), off, prompt
- Agent availability check: command_exists "${agent_cmd%% *}"
- Warning if agent not found, but allow session creation
- Agent launched via tmux send-keys in new session

## Dependencies

**Required:**
- tmux >= 3.0 (3.2+ for popup support)
- git >= 2.5 (worktree support)
- fzf >= 0.20 (fuzzy finder)
- jq (JSON processing)

**Optional:**
- bat (syntax highlighting in previews, fallback to cat)
- gum (prettier prompts, fallback to read)
- AI agent CLI (claude, gemini, opencode, etc.)

## Key Design Decisions

1. **JSON metadata over tmux environment variables** - Persistent, queryable, supports complex data structures
2. **Popup-first UI** - Better UX than split windows, with automatic fallback
3. **Tilde expansion everywhere** - Users expect ~/path to work
4. **Agent-agnostic** - Works with any CLI tool, not tied to specific agent
5. **Orphan handling** - Detects and repairs inconsistent states automatically
6. **Sanitized naming** - Filesystem-safe session and directory names
7. **Interactive prompts from /dev/tty** - Works in popup/split window contexts

## Common Issues & Solutions

**Prompt input not working in popups:**
- Ensure reading from /dev/tty, not stdin
- Write prompts to stderr, not stdout
- Don't use set -e in scripts with user interaction

**Keybindings not working:**
- Use display-popup directly, not run-shell wrapper
- Check tmux version for popup support
- Ensure scripts are executable (chmod +x)

**Path expansion issues:**
- Always use expand_tilde() for user-provided paths
- Handle tilde in configuration, not just runtime

**Git worktree conflicts:**
- Check if branch is already checked out before git worktree add
- Provide clear error messages about conflicts
- Offer alternative actions (rename, cancel)
