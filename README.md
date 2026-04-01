<p align="center">
  <h1 align="center">tmux-worktree-agent</h1>
  <p align="center">
    <strong>Human multithreading for AI-assisted development</strong>
  </p>
  <p align="center">
    Run multiple AI coding agents in parallel — one keybind creates an isolated git worktree + tmux session, each with its own agent instance.
  </p>
  <p align="center">
    <a href="#-quick-start"><img src="https://img.shields.io/badge/-Quick_Start-blue?style=for-the-badge" alt="Quick Start"/></a>
    <a href="#-features"><img src="https://img.shields.io/badge/-Features-green?style=for-the-badge" alt="Features"/></a>
    <a href="#-architecture"><img src="https://img.shields.io/badge/-Architecture-purple?style=for-the-badge" alt="Architecture"/></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-yellow?style=for-the-badge" alt="License: MIT"/></a>
  </p>
</p>

<br/>

<!-- <p align="center">
  <img src="docs/demo.gif" alt="tmux-worktree-agent demo" width="800"/>
</p> -->

<p align="center"><em>Create a worktree session → browse & switch with fzf → agent status updates live in the status bar</em></p>

---

## Why?

You're using Claude Code / Gemini CLI / Codex to write features. You want to work on OAuth **and** refactor the DB layer **and** write tests — all at the same time.

But one terminal, one branch, one agent session can only do one thing.

**tmux-worktree-agent** removes the bottleneck: press one key, get a fully isolated development context — its own branch, its own directory, its own agent. Scale yourself.

---

## 🚀 Quick Start

### Requirements

| Dependency | Version | Purpose |
|:-----------|:--------|:--------|
| **tmux** | 3.0+ (3.2+ for popups) | Core runtime |
| **git** | 2.5+ | Worktree support |
| **fzf** | 0.20+ | Interactive selection |
| **jq** | any | Metadata handling |

Optional: `bat` (syntax-highlighted previews), `gum` (prettier prompts), any AI agent CLI.

### Install with TPM

Add to your `~/.tmux.conf`:

```tmux
set -g @plugin 'KMerdan/tmux-worktree-agent'
```

Reload and install:

```bash
# Inside tmux
prefix + I
```

### Manual Install

```bash
git clone https://github.com/KMerdan/tmux-worktree-agent \
    ~/.tmux/plugins/tmux-worktree-agent
```

Add to `~/.tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/tmux-worktree-agent/worktree-agent.tmux
```

### First 3 Keybindings

| Keybind | What it does |
|:--------|:-------------|
| `prefix + C-w` | **Create** — full wizard: select branch, name topic, spawn worktree + session + agent |
| `prefix + w` | **Browse** — fzf session browser: switch, delete, preview, recover |
| `prefix + T` | **Tasks** — batch-dispatch from Markdown task files |

That's it. You're running.

---

## ✨ Features

### Core Workflow

| Feature | Description |
|:--------|:------------|
| **One-keybind create** | `prefix + C-w` creates a git worktree, tmux session, and launches an agent — one step |
| **fzf session browser** | Fuzzy search, switch, delete, and recover sessions with a live preview pane |
| **Agent status bar** | Color-coded per-session agent state: ● working · ⏎ waiting · ◌ off · ✗ dead |
| **Quick create** | `prefix + W` — auto-detect branch, just type a topic name |
| **Agent-agnostic** | Works with `claude`, `gemini`, `opencode`, `codex`, `aider`, or any CLI tool |

### Task System

| Feature | Description |
|:--------|:------------|
| **Markdown task DSL** | Define tasks in structured Markdown with IDs, priorities, and dependency graphs |
| **Batch dispatch** | Multi-select tasks from `task.md` and spawn all sessions at once |
| **Task sidebar** | Persistent kanban-style task board — dispatch, navigate, and track from one place |
| **Task prompt menu** | Unified entry for generating, starting, updating, and merging tasks |

### Context & Collaboration

| Feature | Description |
|:--------|:------------|
| **Shared context** | `.shared/context.md` — project-level knowledge shared across all agents (read-only) |
| **Private task context** | Each agent gets `preamble + task block` — global constraints plus local objective |
| **Broadcast protocol** | Agents write change notifications to `.shared/broadcasts/TASK-<id>.md` — async, zero-conflict |
| **Merge orchestrator** | Sends structured merge prompts to agents: dependency-ordered, diff-verified, conflict-safe |

### Resilience

| Feature | Description |
|:--------|:------------|
| **Orphan detection** | Detect and repair session/worktree/metadata mismatches |
| **Auto-cleanup** | Stale metadata entries are purged automatically |
| **Session registration** | Adopt existing tmux sessions into the plugin's management |
| **Graceful destroy** | `prefix + K` cleans up session + worktree + branch + metadata in correct order |

---

## 📖 Keybinding Reference

| Keybind | Script | Description |
|:--------|:-------|:------------|
| `prefix + w` | `browse-sessions.sh` | fzf browser — switch, delete, preview sessions |
| `prefix + C-w` | `create-worktree.sh` | Full create: enter branch + topic |
| `prefix + W` | `create-worktree.sh --quick` | Quick create: auto-detect branch, enter topic |
| `prefix + K` | `kill-worktree.sh` | Remove session, worktree, and metadata |
| `prefix + R` | `reconcile.sh` | Scan and repair orphaned sessions/worktrees |
| `prefix + D` | `session-description.sh` | Edit the description for the current session |
| `prefix + A` | `register-session.sh` | Register current session into plugin metadata |
| `prefix + T` | `task-selector.sh` | Parse tasks from Markdown, batch-spawn sessions |
| `prefix + G` | `task-prompt-menu.sh` | Task prompt menu: generate, start, merge, update |
| `prefix + S` | `task-sidebar.sh` | Toggle persistent task sidebar (split pane) |
| `prefix + E` | `open-task.sh` | Open task file in popup viewer |
| `prefix + O` | `window-pane-ops.sh` | Window and pane layout operations |
| `prefix + ?` | `show-helper-fzf.sh` | Help popup with git quick-actions |

All keybindings are customizable via `~/.tmux.conf`:

```tmux
set -g @worktree-browser-key 'w'
set -g @worktree-create-key 'C-w'
set -g @worktree-quick-create-key 'W'
# ... see Configuration section for full list
```

---

## ⚙️ Configuration

```tmux
# ~/.tmux.conf

set -g @plugin 'KMerdan/tmux-worktree-agent'

# Where worktrees are stored (default: ~/.worktrees)
set -g @worktree-path '~/.worktrees'

# Default agent command (default: claude)
set -g @worktree-agent-cmd 'claude'

# Auto-launch agent: on | off | prompt (default: prompt)
set -g @worktree-auto-agent 'prompt'

# Known agents for status detection (default: claude)
set -g @worktree-agent-list 'claude'
```

### Supported Agents

| Agent | `@worktree-agent-cmd` | Notes |
|:------|:----------------------|:------|
| Claude Code | `claude` | Default |
| Gemini CLI | `gemini` | |
| OpenCode | `opencode` | |
| Codex | `codex` | |
| Aider | `aider` | |
| Any CLI tool | `<command>` | Launched via `tmux send-keys` |

---

## 🏗 Architecture

### System Overview

<p align="center">
  <img src="docs/architecture.png" alt="Architecture Overview" width="800"/>
</p>

The plugin is structured as **four layers of capability**:

```
Layer 4  │  Collaboration    .shared/context.md · broadcasts · merge-orchestrator
Layer 3  │  Task Modeling     task-parser · task-selector · task-sidebar · task-prompt-menu
Layer 2  │  State Persistence metadata.json · browse-sessions · reconcile
Layer 1  │  Resource Isolation git worktree · tmux session · AI agent CLI
```

Each layer answers a progressively harder question:

1. **How do I isolate tasks?** → worktree + session + agent per task
2. **How do I remember and recover?** → persistent JSON metadata + runtime reconciliation
3. **How do I go from plan to execution?** → Markdown task DSL + batch dispatch + sidebar
4. **How do agents collaborate and converge?** → shared context + broadcasts + merge orchestration

### Module Map

```
worktree-agent.tmux                   # Entry: config + keybind assembly
├── scripts/
│   ├── create-worktree.sh            # Create worktree + session + agent
│   ├── browse-sessions.sh            # fzf session browser + recovery
│   ├── kill-worktree.sh              # Destroy session + worktree + branch
│   ├── reconcile.sh                  # System-wide consistency check
│   ├── status-agents.sh              # Status bar agent detection
│   ├── shell-init.sh                 # Session banner + description
│   ├── task-selector.sh              # Batch dispatch from Markdown
│   ├── task-sidebar.sh               # Persistent task kanban
│   ├── task-prompt-menu.sh           # Task lifecycle prompt hub
│   ├── task-preview.sh               # fzf task preview
│   ├── merge-orchestrator.sh         # Merge prompt generation
│   ├── open-task.sh                  # Task file popup viewer
│   ├── register-session.sh           # Adopt existing sessions
│   ├── session-description.sh        # Session semantic labels
│   ├── session-info.sh               # Status line formatting
│   ├── prompt-preview.sh             # fzf prompt preview helper
│   ├── utils.sh                      # Shared utilities (git, tmux, path helpers)
│   ├── window-pane-ops.sh            # Layout operations
│   └── show-helper-fzf.sh            # Help panel
└── lib/
    ├── metadata.sh                   # JSON metadata CRUD
    └── task-parser.sh                # Markdown task DSL parser
```

### Create Flow

When you press `prefix + C-w`, this is what happens:

```mermaid
sequenceDiagram
    participant U as User
    participant T as tmux keybind
    participant C as create-worktree.sh
    participant G as git
    participant M as metadata.json
    participant S as tmux
    participant A as Agent CLI

    U->>T: prefix + C-w
    T->>C: Open popup
    C->>C: Check dependencies
    C->>C: Select branch + enter topic
    C->>G: git worktree add ~/.worktrees/<repo>/<topic>
    G-->>C: Worktree ready
    C->>S: new-session -s <repo>-<topic>
    C->>M: Save session metadata
    C->>A: send-keys <agent-cmd>
    C->>S: switch-client → new session
```

The script handles real-world edge cases: duplicate session names (attach / rename / cancel), existing worktree directories (reuse if valid), branch already checked out elsewhere (use directly / derive `wt/<topic>` / session-only).

### Context Sharing Model

<p align="center">
  <img src="docs/context-sharing.png" alt="Context Sharing Model" width="800"/>
</p>

When tasks are dispatched, context is split into three layers:

| Layer | Location | Scope | Mutability |
|:------|:---------|:------|:-----------|
| **Shared context** | `.shared/context.md` | All agents | Read-only |
| **Private context** | `<worktree>/<task>.md` | Single agent | Read-write |
| **Broadcasts** | `.shared/broadcasts/TASK-<id>.md` | Cross-agent | Append-only per agent |

**Shared context** is extracted from the `task.md` preamble (everything before the first `---`). It contains project-level knowledge: architecture, constraints, conventions.

**Private context** is a merged file: `preamble + task block`. Each agent knows the global rules and its specific objective.

**Broadcasts** implement async message passing. Each agent writes only its own file to communicate changes that affect others. No shared mutable state, no conflicts, no coordination overhead.

### Task Lifecycle

<p align="center">
  <img src="docs/task-lifecycle.png" alt="Task Lifecycle" width="800"/>
</p>

```mermaid
flowchart LR
    A["📝 Model<br/>Generate task.md"] --> B["📋 Dispatch<br/>task-selector / sidebar"]
    B --> C["🤖 Execute<br/>Agent per worktree"]
    C --> D["📡 Broadcast<br/>.shared/broadcasts/"]
    D --> E["🔀 Converge<br/>merge-orchestrator"]
    E -.->|"Update status"| A
```

1. **Model** — Generate structured `task.md` with IDs, priorities, and dependency graphs
2. **Dispatch** — Multi-select tasks, batch-create worktree sessions
3. **Execute** — Each agent works in its own isolated worktree with injected context
4. **Broadcast** — Agents write change notifications for cross-task awareness
5. **Converge** — Merge orchestrator verifies diffs against broadcasts, merges in dependency order

### Session Browser States

The browser cross-checks metadata against reality:

| Icon | State | Meaning | Action |
|:-----|:------|:--------|:-------|
| `●` | Active | Session + worktree both exist | Switch to session |
| `○` | Worktree only | Directory exists, no tmux session | Recreate session |
| `⚠` | Session only | tmux exists, worktree deleted | Recreate worktree or clean up |
| `✗` | Stale | Both gone | Auto-purge metadata |

### Agent Status Detection

| Icon | Color | State | How it's detected |
|:-----|:------|:------|:------------------|
| `●` | 🟢 Green | Working | CPU >= 2% or pane output within 10s |
| `⏎` | 🟠 Orange | Waiting for input | Prompt UI detected, no active output |
| `◌` | ⚪ Grey | Not running | No agent process found |
| `✗` | 🔴 Red | Dead | tmux session doesn't exist |

---

## 📝 Task File Format

Tasks are defined in Markdown with a simple structure:

```markdown
Project background and shared constraints go here.
This "preamble" is shared with every agent as read-only context.

---

### Task ID: TASK-001
**Title**: Implement OAuth2 authentication
**Status**: `[ ]` pending
**Priority**: P1
**Depends On**: None
**Blocks**: TASK-003

Detailed description of what needs to be done...

---

### Task ID: TASK-002
**Title**: Refactor database query layer
**Status**: `[ ]` pending
**Priority**: P2
**Depends On**: None

Migrate raw SQL queries to ORM...

---

### Task ID: TASK-003
**Title**: Write end-to-end tests
**Status**: `[ ]` pending
**Priority**: P2
**Depends On**: TASK-001

E2E tests for the OAuth flow...
```

**Rules:**
- Everything before the first `---` is the **preamble** (shared context)
- Each task starts with `### Task ID: <id>`
- `**Title**:` is required; all other fields are optional
- `**Depends On**:` / `**Blocks**:` define the task dependency DAG
- Tasks are separated by `---` horizontal rules

---

## 🔌 Optional Integrations

### Status bar — repo name

```tmux
set -g status-left '#(~/.tmux/plugins/tmux-worktree-agent/scripts/status-repo.sh) '
```

Agent status is **automatically appended** to `status-right` — no configuration needed.

### Shell banner

Add to `~/.bashrc` or `~/.zshrc`:

```bash
source ~/.tmux/plugins/tmux-worktree-agent/scripts/shell-init.sh
```

Displays session context on shell startup:

```
╭─ Worktree Session ────────────────────────────╮
│ Repo:   my-project                             │
│ Branch: feature/auth                           │
│ Topic:  oauth-impl                             │
│                                                │
│ 📝 Implement OAuth2 with GitHub and Google     │
╰────────────────────────────────────────────────╯
```

### Window auto-renaming

```tmux
set -g status-right '#(~/.tmux/plugins/tmux-worktree-agent/scripts/auto-rename-windows.sh > /dev/null 2>&1; echo)'
```

---

## 🔧 Troubleshooting

| Problem | Solution |
|:--------|:---------|
| Prompts not responding in popups | All prompts read from `/dev/tty`. Check if a wrapper closes stdin. |
| Keybindings do nothing | `display-popup` requires tmux 3.2+. Check with `tmux -V`. |
| Sessions appear but don't exist | Run `prefix + R` (reconcile). Stale entries are auto-cleaned. |
| Can't create worktree — branch conflict | Git doesn't allow the same branch in two worktrees. Use a different branch. |
| Path expansion not working | Set `@worktree-path` before the plugin loads in `~/.tmux.conf`. |

---

## 📄 License

[MIT](LICENSE)

---

<p align="center">
  <strong>Stop context-switching. Start multithreading.</strong><br/>
  <a href="https://github.com/KMerdan/tmux-worktree-agent">⭐ Star on GitHub</a>
</p>
