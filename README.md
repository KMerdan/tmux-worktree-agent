# tmux-worktree-agent

A tmux plugin that optimizes workflows for managing multiple AI coding agent instances across git worktrees. Enable human multithreading by working on different topics/branches simultaneously with isolated tmux sessions.

## Features

- **One-Keybind Workflow**: Create isolated worktree + tmux session with a single keystroke
- **Agent-Agnostic**: Works with any AI coding CLI (Claude Code, Gemini, OpenCode, Codex, etc.)
- **Smart Browser**: Fuzzy search and switch between worktree sessions with fzf
- **Orphan Detection**: Automatically detects and helps fix orphaned sessions/worktrees
- **TPM Ready**: Simple installation via Tmux Plugin Manager
- **Status Line Integration**: Visual indicators for worktree sessions

## Why?

Modern AI coding workflows often involve:
- Testing different approaches in parallel
- Working on multiple features/bugs simultaneously
- Keeping agent context isolated per topic
- Switching between tasks without losing state

This plugin makes it seamless to manage multiple git worktrees, each with its own tmux session and AI agent instance.

## Installation

### Prerequisites

**Required:**
- tmux >= 3.0
- git >= 2.5
- fzf >= 0.20
- jq (JSON processing)

**Optional:**
- claude/gemini/opencode/codex (or any AI coding CLI)
- bat (for syntax highlighted previews, fallback to cat)
- gum (for prettier prompts, fallback to read)

### Install with TPM

Add to `~/.tmux.conf`:

```bash
set -g @plugin 'your-github-username/tmux-worktree-agent'

# Optional configuration
set -g @worktree-path '~/.worktrees'              # Worktree storage location
set -g @worktree-agent-cmd 'claude'               # Agent command
set -g @worktree-auto-agent 'on'                  # 'on', 'off', 'prompt'
```

Then reload tmux config and install:
```bash
# Reload tmux config
tmux source-file ~/.tmux.conf

# Install plugins (prefix + I)
```

## Usage

### Quick Start

1. **Create a new worktree session**: `prefix + C-w`
   - Enter branch name
   - Enter topic/description
   - Plugin creates worktree, session, and launches agent

2. **Browse sessions**: `prefix + w`
   - Fuzzy search all sessions
   - `Enter` to switch
   - `Ctrl-d` to delete
   - `Tab` to toggle preview

3. **Quick create from current branch**: `prefix + W`
   - Auto-detects current branch
   - Just enter topic name

4. **Kill current worktree**: `prefix + K`
   - Removes session, worktree, and metadata

5. **Reconcile orphaned states**: `prefix + R`
   - Scans for orphaned sessions/worktrees
   - Shows summary and fix options

### Workflows

#### Starting a New Feature

```bash
# From main repo
prefix + C-w

# Enter:
Branch: feature/auth
Topic: user-authentication

# Result:
# - Worktree created at: ~/.worktrees/myrepo/user-authentication
# - Session created: myrepo-user-authentication
# - Agent launched: claude
# - Automatically switched to new session
```

#### Quick Worktree from Current Branch

```bash
# While on branch feature/auth
prefix + W

# Enter:
Topic: testing-oauth

# Result:
# - Uses current branch (feature/auth)
# - Creates worktree + session instantly
```

#### Switching Between Sessions

```bash
prefix + w

# fzf browser appears:
# ● myrepo-user-authentication  feature/auth      ~/.worktrees/...
# ● myrepo-bugfix-login         bugfix/login      ~/.worktrees/...
# ○ myrepo-refactor             main              ~/.worktrees/...

# Type to fuzzy search, Enter to switch
```

#### Cleaning Up

```bash
# From within a worktree session
prefix + K

# Confirms, then:
# - Kills tmux session
# - Removes git worktree
# - Cleans metadata
# - Switches to another session
```

### Browser Interface

The session browser (`prefix + w`) provides:

**List View:**
- `●` - Active session (session + worktree exist)
- `○` - Worktree only (no session running)
- `⚠` - Session only (worktree deleted)
- `✗` - Stale (both missing, will be cleaned)

**Keybindings:**
- `Enter` - Switch to session (or recreate if needed)
- `Ctrl-d` - Delete session + worktree
- `Ctrl-r` - Refresh list
- `Tab` - Toggle preview
- `Esc` - Cancel

**Preview Pane:**
Shows:
- Session metadata (repo, branch, created date)
- Active windows
- Git status (if worktree exists)
- Worktree path

### Orphaned States

The plugin automatically handles orphaned states:

**Session exists, worktree deleted:**
- Shows `⚠` in browser
- Offers to: Recreate worktree / Kill session / Cancel

**Worktree exists, no session:**
- Shows `○` in browser
- Offers to: Create session / Delete worktree / Cancel

**Both missing (stale):**
- Automatically cleaned from metadata
- Run `prefix + R` to scan and clean

## Configuration

### Default Keybindings

| Key | Action |
|-----|--------|
| `prefix + w` | Browse/switch worktree sessions |
| `prefix + C-w` | Create new worktree session (full) |
| `prefix + W` | Quick create (auto-detect current branch) |
| `prefix + K` | Kill current worktree + session |
| `prefix + R` | Reconcile/refresh metadata |

### Custom Keybindings

```bash
# Change keybindings
set -g @worktree-browser-key 'w'
set -g @worktree-create-key 'C-w'
set -g @worktree-quick-create-key 'W'
set -g @worktree-kill-key 'K'
set -g @worktree-refresh-key 'R'
```

### Agent Configuration

**Use different AI agents:**

```bash
# Claude Code (default)
set -g @worktree-agent-cmd 'claude'

# Gemini Code
set -g @worktree-agent-cmd 'gemini code'

# OpenCode
set -g @worktree-agent-cmd 'opencode'

# Codex
set -g @worktree-agent-cmd 'codex'

# No agent (manual workflow)
set -g @worktree-auto-agent 'off'

# Prompt each time
set -g @worktree-auto-agent 'prompt'
```

**Agent behavior:**

```bash
# Auto-launch agent when creating session (default)
set -g @worktree-auto-agent 'on'

# Never launch agent
set -g @worktree-auto-agent 'off'

# Ask each time
set -g @worktree-auto-agent 'prompt'
```

### Storage Location

```bash
# Custom worktree location (default: ~/.worktrees)
set -g @worktree-path '~/projects/worktrees'

# Worktrees will be created at:
# ~/projects/worktrees/<repo-name>/<topic>/
```

## Architecture

### Directory Structure

```
~/.worktrees/
└── myrepo/
    ├── feature-auth/       # Worktree for feature/auth
    ├── bugfix-login/       # Worktree for bugfix/login
    └── testing-oauth/      # Worktree for feature/auth (different topic)
```

### Metadata

Session metadata stored in: `~/.tmux/plugins/tmux-worktree-agent/.worktree-sessions.json`

```json
{
  "myrepo-feature-auth": {
    "repo": "myrepo",
    "topic": "feature-auth",
    "branch": "feature/auth",
    "worktree_path": "/Users/you/.worktrees/myrepo/feature-auth",
    "main_repo_path": "/Users/you/projects/myrepo",
    "created_at": "2026-01-18T15:30:00Z",
    "agent_running": true
  }
}
```

## Examples

### Multi-Agent Workflow

```bash
# Terminal 1: Working on authentication
prefix + C-w
Branch: feature/auth
Topic: oauth-impl
# Now in: myrepo-oauth-impl with Claude running

# Terminal 2: Testing a fix
prefix + W  (on bugfix/login branch)
Topic: testing-fix
# Now in: myrepo-testing-fix with Claude running

# Terminal 3: Exploring refactor
prefix + C-w
Branch: refactor/database
Topic: schema-changes
# Now in: myrepo-schema-changes with Claude running

# Switch between them instantly:
prefix + w
# Fuzzy search, pick one, press Enter
```

### Working Without Agents

```bash
# Disable auto-agent
set -g @worktree-auto-agent 'off'

# Or when creating:
prefix + C-w
Branch: experiment/new-idea
Topic: spike
# Session created, no agent launched
# Work manually or launch agent later
```

## Troubleshooting

### Agent command not found

**Symptom:** Warning "Agent command 'claude' not found"

**Solution:**
- Ensure agent is installed and in PATH
- Or change to available agent: `set -g @worktree-agent-cmd 'your-agent'`
- Or disable auto-launch: `set -g @worktree-auto-agent 'off'`

### Orphaned worktrees

**Symptom:** Worktrees exist but sessions don't

**Solution:**
```bash
prefix + R          # Reconcile
prefix + w          # Browse, select orphaned worktree
Enter               # Create session for it
```

### Stale metadata

**Symptom:** Sessions appear in browser but don't exist

**Solution:**
```bash
prefix + R          # Auto-cleans stale entries
```

### Permission issues

**Symptom:** Cannot create worktree

**Solution:**
- Check write permissions on worktree path
- Ensure git repository is accessible
- Verify worktree path: `echo ${WORKTREE_PATH:-$HOME/.worktrees}`

## Compatibility

- **OS**: Linux, macOS, WSL2
- **Shell**: bash, zsh
- **tmux version**: 3.0+ (3.2+ for popup support)
- **Works with**: TPM, catppuccin-tmux, tmux-fzf, and other plugins

## Status Line Integration

Get session info for your status line:

```bash
# In tmux.conf status-right
set -g status-right '#(~/.tmux/plugins/tmux-worktree-agent/scripts/session-info.sh "#{session_name}" "short")'

# Formats:
# icon         -> 🌳
# branch       -> feature/auth
# topic        -> oauth-impl
# short        -> 🌳 feature/auth
# full         -> 🌳 myrepo/oauth-impl (feature/auth)
# status-line  -> [myrepo-oauth-impl] 🌳 feature/auth
```

## Development

### Project Structure

```
tmux-worktree-agent/
├── worktree-agent.tmux          # TPM entry point
├── scripts/
│   ├── create-worktree.sh       # Create worktree + session
│   ├── browse-sessions.sh       # fzf browser
│   ├── kill-worktree.sh         # Cleanup
│   ├── session-info.sh          # Get metadata
│   ├── reconcile.sh             # Fix orphaned states
│   └── utils.sh                 # Shared utilities
├── lib/
│   └── metadata.sh              # JSON metadata manager
└── docs/
    └── plans/
        └── 2026-01-18-worktree-agent-design.md
```

### Testing

See design document for comprehensive testing checklist.

## License

MIT

## Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Test thoroughly
4. Submit a pull request

## Credits

Built for developers who multitask with AI coding agents.

Inspired by the workflow of managing multiple Claude Code instances across different git worktrees.
