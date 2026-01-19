# Session Description Feature Design

**Date:** 2026-01-19
**Status:** Approved

## Overview

Add a description field to session metadata that allows users to provide context about what each worktree/session is for. This description gives AI coding agents initial context when they start working in a session.

## Problem Statement

When AI agents start in a new worktree session, they have no context about what the user is working on. Users have to repeatedly explain the purpose of the session. A stored description would:

- Give agents immediate context about the session's purpose
- Serve as a reminder for users when switching between multiple sessions
- Improve agent effectiveness by providing upfront context

## Design

### 1. Metadata Structure Changes

**Extend JSON metadata in `.worktree-sessions.json`:**

```json
{
  "repo-name-topic": {
    "repo": "repo-name",
    "topic": "topic",
    "branch": "feat/branch",
    "worktree_path": "/path/to/worktree",
    "main_repo_path": "/path/to/main",
    "created_at": "2026-01-19T10:00:00Z",
    "agent_running": true,
    "description": "User-provided context about this session"
  }
}
```

**Changes to `lib/metadata.sh`:**

- `save_session()`: Add 8th parameter `description` (defaults to empty string)
- Add `update_session_description(session_name, description)`: Updates only description field
- Add `get_session_description(session_name)`: Retrieves description

**Backward compatibility:**
- Description field is optional
- Existing metadata continues to work (missing field treated as empty)

### 2. Shell Hook for Description Prompt

**New file: `scripts/shell-init.sh`**

Provides a shell function that users add to their shell config (~/.bashrc, ~/.zshrc):

```bash
source ~/.tmux/plugins/tmux-worktree-agent/scripts/shell-init.sh
```

**Function behavior:**
- Runs automatically on shell startup
- Only activates in tmux sessions created by the plugin
- Checks if current session has a description in metadata
- If no description: prompts user and saves it
- Displays formatted banner with repo, branch, topic, and description

**Example banner:**
```
╭─ Worktree Session ─────────────────────────────────╮
│ Repo:   tmux-worktree-agent                        │
│ Branch: feat/add-description                       │
│ Topic:  add-description                            │
│                                                    │
│ 📝 Implementing user-provided descriptions for    │
│    sessions to give AI agents initial context     │
╰────────────────────────────────────────────────────╯
```

**Why shell hook instead of tmux hook:**
- Agent-agnostic (works with any AI tool)
- Users see banner every time they open a shell in the worktree
- Compatible with both tmux popup creation and manual cd into worktree
- No tmux version dependencies

### 3. Helper Script for Agent Access

**New file: `scripts/session-description.sh`**

Provides both interactive and programmatic access:

**Usage:**
```bash
# Get description (for agents/scripts)
session-description.sh get [session-name]

# Set description programmatically
session-description.sh set [session-name] "Description text"

# Interactive prompt
session-description.sh prompt [session-name]
```

**Features:**
- Auto-detects current tmux session if session-name omitted
- Falls back to worktree path detection
- Uses `/dev/tty` for input (popup compatibility)
- Returns empty string if no description set

**Integration with AI agents:**
- Agents can call `session-description.sh get` to read description
- Works in Claude Code SessionStart hooks
- Compatible with other agents (Gemini, OpenCode, etc.)

### 4. Integration with Existing Workflows

**Changes to `scripts/create-worktree.sh`:**
- Update `save_session()` call to pass empty description parameter
- No changes to user-facing workflow
- Description collection happens later via shell hook

**Changes to `scripts/browse-sessions.sh`:**
- Add description to preview pane (truncated to 100 chars)
- Shows after branch info

**Changes to `scripts/session-info.sh`:**
- Add `--format description` option
- Returns description or empty string

**New keybinding (optional):**
- `prefix + D`: Edit/update session description
- Opens `session-description.sh prompt` in popup
- Useful for updating without restarting shell

### 5. User Experience Flow

**First time in new session:**
1. User creates worktree via `prefix + C-w` (no description prompt)
2. Tmux session created, agent may launch automatically
3. Shell starts → shell-init.sh detects no description
4. Prompts: "What is this session about? (Description for AI agents)"
5. User enters description, it's saved to metadata
6. Banner displays with all session info + description
7. Agent sees banner and can access description programmatically

**Subsequent shell sessions:**
1. Shell starts → shell-init.sh loads description from metadata
2. Banner displays immediately (no prompt)
3. Agent has context from the start

**Updating description:**
- Use `prefix + D` keybinding
- Or run `session-description.sh set "New description"`
- Or run `session-description.sh prompt` for interactive update

## Implementation Notes

**File changes required:**
- `lib/metadata.sh`: Add description support to metadata functions
- `scripts/shell-init.sh`: New file for shell integration
- `scripts/session-description.sh`: New file for description management
- `scripts/create-worktree.sh`: Update save_session call
- `scripts/browse-sessions.sh`: Add description to preview
- `scripts/session-info.sh`: Add description format option
- `worktree-agent.tmux`: Add optional keybinding for editing description
- `README.md`: Document shell integration setup

**Testing considerations:**
- Test with empty/missing descriptions (backward compatibility)
- Test in popup and split-window modes
- Test auto-detection of current session
- Test with very long descriptions (truncation)
- Test banner formatting with various terminal widths

**Optional enhancements (future):**
- Multi-line description support
- Template descriptions for common session types
- Export description to CLAUDE.md or similar file
- Description search in browse-sessions.sh

## Decision Rationale

**Why shell hook over tmux hook?**
- Works with any agent/tool
- Visible on every shell startup (better UX)
- No tmux version dependencies
- Users can opt-in by adding to shell config

**Why prompt on first shell startup instead of during worktree creation?**
- User approved this timing in brainstorming
- Allows users to start working immediately
- Agent can see the description when it matters most
- Less friction in the creation workflow

**Why not use a CLAUDE.md file?**
- Metadata is already JSON-based
- Consistent with existing architecture
- Easier to query and update programmatically
- Can still export to CLAUDE.md in future if needed

**Why optional shell integration?**
- Keeps plugin non-invasive
- Users who don't want descriptions can skip it
- Maintains backward compatibility
- Follows Unix philosophy (tools, not policy)
