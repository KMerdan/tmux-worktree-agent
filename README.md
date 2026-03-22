# tmux-worktree-agent

Run multiple AI coding agents in parallel -- one keybind creates an isolated git worktree + tmux session, each with its own agent instance. Human multithreading for AI-assisted development.

![demo](docs/demo.gif)

> The demo shows: creating a new worktree session with `prefix + C-w`, switching between sessions with the fzf browser (`prefix + w`), and the agent status indicators updating live in the status bar.

---

## Features

- **One-keybind workflow** -- create a git worktree, tmux session, and launch an agent in a single step
- **fzf session browser** -- fuzzy search, switch, and delete sessions with a live preview pane
- **Agent status bar** -- color-coded per-session agent state auto-appended to `status-right`
- **Task batch dispatch** -- parse tasks from Markdown files and spawn multiple agent sessions at once
- **Orphan detection** -- scan for sessions without worktrees and worktrees without sessions, fix interactively
- **Session descriptions** -- attach a purpose string to each session; displayed in a banner on shell start
- **Session registration** -- register any existing tmux session into plugin metadata without a full create flow
- **Agent-agnostic** -- works with `claude`, `gemini`, `opencode`, `codex`, or any CLI tool
- **TPM-ready** -- three lines to install

---

## Requirements

**Required**

| Dependency | Minimum version | Purpose |
|---|---|---|
| tmux | 3.0 (3.2+ for popups) | Core runtime |
| git | 2.5 | Worktree support |
| fzf | 0.20 | Session browser |
| jq | any | Metadata JSON |

**Optional**

| Dependency | Purpose |
|---|---|
| bat | Syntax-highlighted previews (falls back to `cat`) |
| gum | Prettier interactive prompts (falls back to `read`) |
| AI agent CLI | `claude`, `gemini`, `opencode`, `codex`, etc. |

---

## Installation

### TPM (recommended)

Add to `~/.tmux.conf`:

```tmux
set -g @plugin 'KMerdan/tmux-worktree-agent'

# Optional config (all values shown are defaults)
set -g @worktree-path '~/.worktrees'
set -g @worktree-agent-cmd 'claude'
set -g @worktree-auto-agent 'on'
```

Then inside tmux: `prefix + I` to install.

### Manual

```bash
git clone https://github.com/KMerdan/tmux-worktree-agent \
    ~/.tmux/plugins/tmux-worktree-agent

# Add to ~/.tmux.conf
run-shell ~/.tmux/plugins/tmux-worktree-agent/worktree-agent.tmux

# Reload
tmux source-file ~/.tmux.conf
```

---

## Quick Start

Three keybindings to know first:

| Keybind | What it does |
|---|---|
| `prefix + C-w` | Create worktree + session (enter branch and topic) |
| `prefix + w` | Browse all sessions -- switch, delete, preview |
| `prefix + W` | Quick create using the current branch (just enter a topic) |

After creating a session, the plugin:
1. Creates `~/.worktrees/<repo>/<topic>/` as a git worktree
2. Opens a new tmux session named `<repo>-<topic>`
3. Launches the configured agent (unless `@worktree-auto-agent` is `off`)
4. Switches you to the new session

---

## Configuration

### Options

| Option | Default | Description |
|---|---|---|
| `@worktree-path` | `~/.worktrees` | Root directory for all worktrees |
| `@worktree-agent-cmd` | `claude` | Agent command sent to the new session |
| `@worktree-agent-list` | `claude` | Known agents for status detection |
| `@worktree-auto-agent` | `on` | `on` auto-launches, `off` skips, `prompt` asks each time |

### Keybind options

All keybinds are customizable. Set any of these in `~/.tmux.conf` before the plugin loads:

| Option | Default | Description |
|---|---|---|
| `@worktree-browser-key` | `w` | Open session browser |
| `@worktree-create-key` | `C-w` | Create worktree session (full) |
| `@worktree-quick-create-key` | `W` | Quick create from current branch |
| `@worktree-kill-key` | `K` | Kill current worktree + session |
| `@worktree-refresh-key` | `R` | Reconcile orphaned metadata |
| `@worktree-description-key` | `D` | Edit session description |
| `@worktree-cleanup-key` | `C` | Clean up old agent processes |
| `@worktree-ops-key` | `O` | Window/pane operations popup |
| `@worktree-task-selector-key` | `T` | Task batch-dispatch from Markdown |
| `@worktree-task-prompt-key` | `G` | Task prompt menu (generate / merge / update) |
| `@worktree-register-key` | `A` | Register current session into metadata |
| `@worktree-helper-key` | `?` | Show help and git quick-actions |

---

## Keybindings Reference

| Keybind | Script | Description |
|---|---|---|
| `prefix + w` | `browse-sessions.sh` | fzf browser -- switch, delete, preview sessions |
| `prefix + C-w` | `create-worktree.sh` | Full create: enter branch + topic |
| `prefix + W` | `create-worktree.sh --quick` | Quick create: auto-detect branch, enter topic |
| `prefix + K` | `kill-worktree.sh` | Remove session, worktree, and metadata |
| `prefix + R` | `reconcile.sh` | Scan and repair orphaned sessions/worktrees |
| `prefix + D` | `session-description.sh` | Edit the description for the current session |
| `prefix + A` | `register-session.sh` | Register current session into plugin metadata |
| `prefix + T` | `task-selector.sh` | Parse tasks from Markdown, batch-spawn sessions |
| `prefix + G` | `task-prompt-menu.sh` | Task prompt menu: start task, generate, merge, update |
| `prefix + C` | `cleanup-agents.sh` | Interactive cleanup of stale agent processes |
| `prefix + O` | `window-pane-ops.sh` | Window and pane layout operations |
| `prefix + ?` | `show-helper-fzf.sh` | Help popup with one-key git quick-actions |

### Session browser actions (`prefix + w`)

| Key | Action |
|---|---|
| `Enter` | Switch to session (recreates session if worktree-only) |
| `Ctrl-d` | Delete session + worktree |
| `Ctrl-r` | Refresh list |
| `Tab` | Toggle preview pane |
| `Esc` | Cancel |

### Session browser status indicators

**Session column**

| Symbol | Meaning |
|---|---|
| `●` | Active -- session and worktree both exist |
| `○` | Worktree only -- no session running |
| `⚠` | Session only -- worktree has been deleted |
| `✗` | Stale -- both missing, will be cleaned |

**Agent column**

| Symbol | Meaning |
|---|---|
| `●` | Actively working (recent output + CPU activity) |
| `⏎` | Waiting for user input |
| `◌` | Stopped -- no process found |
| `─` | N/A -- session not running |

---

## How It Works

```
prefix + C-w
     |
     +-- Prompts: branch name, topic name
     +-- git worktree add ~/.worktrees/<repo>/<topic>  <branch>
     +-- tmux new-session -s <repo>-<topic>  -c <worktree-path>
     +-- tmux send-keys  "<agent-cmd>"  (if auto-agent = on)
     +-- Saves to .worktree-sessions.json
```

**Metadata** persists at `~/.tmux/plugins/tmux-worktree-agent/.worktree-sessions.json`. Each entry stores repo, topic, branch, worktree path, main repo path, creation time, and description.

**Session names** follow the format `<repo>-<topic>`. Topic names are sanitized: lowercased, `/` replaced with `-`, spaces removed.

**Worktree paths** follow `<@worktree-path>/<repo>/<topic>/`.

---

## Optional Integrations

### Status bar -- repo name in `status-left`

`scripts/status-repo.sh` returns the repo name for the current session (falls back to session name for non-plugin sessions).

```tmux
set -g status-left '#(~/.tmux/plugins/tmux-worktree-agent/scripts/status-repo.sh) '
```

`scripts/status-agents.sh` is **automatically appended** to `status-right` when the plugin loads -- no manual configuration needed.

### Window auto-renaming

`scripts/auto-rename-windows.sh` renames windows to `<agent>:<branch>` (e.g., `claude:feature/auth`) by inspecting child processes in each pane.

```tmux
# Option A: periodic via status bar
set -g status-right '#(~/.tmux/plugins/tmux-worktree-agent/scripts/auto-rename-windows.sh > /dev/null 2>&1; echo)'

# Option B: on-demand via tmux hook
set-hook -g session-window-renamed "run '~/.tmux/plugins/tmux-worktree-agent/scripts/auto-rename-windows.sh'"
```

**Performance note:** This scans `pgrep`/`ps` for every pane on each refresh. Keep `status-interval` at 5s or higher. Disable tmux's built-in auto-rename to prevent conflicts:

```tmux
set -g allow-rename off
set -wg automatic-rename off
```

### Shell banner and description prompt

`scripts/shell-init.sh` displays a context banner on shell startup in plugin-managed sessions and prompts for a description if one hasn't been set.

Add to `~/.bashrc` or `~/.zshrc`:

```bash
source ~/.tmux/plugins/tmux-worktree-agent/scripts/shell-init.sh
```

Example banner:

```
+-- Worktree Session ----------------------------------------+
| Repo:   my-project                                         |
| Branch: feature/auth                                       |
| Topic:  oauth-impl                                         |
|                                                            |
| Implement OAuth2 with GitHub and Google                    |
+------------------------------------------------------------+
```

---

## Agent Support

| Agent | `@worktree-agent-cmd` | Notes |
|---|---|---|
| Claude Code | `claude` | Default |
| Gemini | `gemini` | |
| OpenCode | `opencode` | |
| Codex | `codex` | |
| Aider | `aider` | |
| Any CLI tool | `<command>` | Launched via `tmux send-keys` -- works with any interactive CLI |

```tmux
# Example: use opencode, prompt before launching
set -g @worktree-agent-cmd 'opencode'
set -g @worktree-auto-agent 'prompt'
```

If the agent binary is not found in `PATH`, the plugin warns but still creates the session so you can launch manually.

---

## Troubleshooting

**Input prompts not responding in popups** -- All prompts read from `/dev/tty`. If a custom wrapper closes stdin, prompts will hang. Run plugin scripts directly from keybindings.

**Keybindings silently do nothing** -- `display-popup` requires tmux 3.2+. Check with `tmux -V`.

**Sessions appear in browser but don't exist** -- Run `prefix + R` (reconcile). Stale metadata is auto-cleaned on browser open.

**Cannot create worktree -- branch conflict** -- Git doesn't allow the same branch in two worktrees. Use a different branch or `prefix + W` for a new topic on the same base.

**Path expansion not working** -- Set `@worktree-path` in `tmux.conf` before the plugin loads.

---

## License

MIT
