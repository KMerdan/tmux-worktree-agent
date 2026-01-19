# Agent Status Indicators in FZF Browser

**Date:** 2026-01-19
**Status:** Approved
**Author:** Brainstorming session

## Overview

Enhance the existing fzf session browser (`prefix + w`) to display real-time agent status indicators, allowing users to see which sessions have agents actively working vs waiting for input.

## Motivation

Users managing multiple AI agent sessions across worktrees need to know which sessions require attention. Currently, the browser shows session/worktree status but not agent activity state. Adding agent status helps users prioritize which session to switch to.

## Design

### Status Indicators

**Existing (Session + Worktree):**
- `●` - Session + worktree both exist (Active)
- `○` - Worktree only (no session running)
- `⚠` - Session only (worktree deleted)
- `✗` - Both missing (stale)

**New (Agent Status):**
- `●` - Agent working (recent output + CPU usage)
- `○` - Agent waiting (idle, low CPU, process exists)
- `◌` - Agent stopped (no process running)
- `─` - N/A (session not running)

### Display Format

```
[session status] [agent status] [session_name] [branch] [path]

● ● tmux-worktree-agent-feat   feature/test   ~/.worktrees/...
● ○ tmux-worktree-agent-main   main           ~/.worktrees/...
● ◌ tmux-worktree-agent-bug    bugfix/login   ~/.worktrees/...
○ ─ tmux-worktree-agent-old    old-branch     ~/.worktrees/...
⚠ ● tmux-worktree-agent-gone   test           ~/.worktrees/...
```

### Detection Logic

Agent status determined by:

1. **Process Check** - Is agent process running in session?
   - Extract agent command from `$WORKTREE_AGENT_CMD`
   - Find child processes of session's main pane
   - If no process found → `◌` (stopped)

2. **Activity Check** - Recent pane output (last 15 seconds)
   - Use `#{pane_activity}` timestamp from tmux
   - Compare against current time

3. **CPU Check** - Is process consuming resources?
   - Use `ps -p $pid -o %cpu=`
   - Threshold: > 5% considered active

4. **Status Decision**:
   - No session → `─`
   - No process → `◌`
   - Recent activity (< 15s) + CPU > 5% → `●` (working)
   - Process exists but idle → `○` (waiting)

### Configuration

Optional tmux options (future enhancement):
- `@worktree-agent-activity-threshold` - Seconds for "recent" activity (default: 15)
- `@worktree-agent-cpu-threshold` - CPU % threshold (default: 5)

## Implementation

### Files Modified

**scripts/browse-sessions.sh:**
1. Add `get_agent_status()` function
2. Modify `build_session_list()` to call it for each session
3. Update printf format to include agent status column

### Function: get_agent_status()

```bash
get_agent_status() {
    local session_name="$1"

    # If session doesn't exist, return N/A
    if ! tmux has-session -t "$session_name" 2>/dev/null; then
        echo "─"
        return
    fi

    # Get agent command from environment
    local agent_cmd="${WORKTREE_AGENT_CMD:-claude}"
    local agent_process="${agent_cmd%% *}"  # First word only

    # Find agent process in session
    local pane_pid=$(tmux list-panes -t "$session_name" -F "#{pane_pid}" | head -1)
    local agent_pid=$(pgrep -P "$pane_pid" "$agent_process" 2>/dev/null)

    if [ -z "$agent_pid" ]; then
        echo "◌"  # No agent process
        return
    fi

    # Check activity: output in last 15 seconds
    local last_activity=$(tmux display-message -t "$session_name" -p "#{pane_activity}")
    local current_time=$(date +%s)
    local time_diff=$((current_time - last_activity))

    # Check CPU usage
    local cpu_usage=$(ps -p "$agent_pid" -o %cpu= 2>/dev/null | awk '{print int($1)}')

    if [ "$time_diff" -lt 15 ] && [ "$cpu_usage" -gt 5 ]; then
        echo "●"  # Working
    else
        echo "○"  # Waiting/idle
    fi
}
```

### Changes to build_session_list()

After line 129 (status icon determination), add:

```bash
# Get agent status
local agent_status="─"
if $session_exists; then
    agent_status=$(get_agent_status "$session")
fi
```

Update printf (line 132):

```bash
printf "%-2s %-2s %-30s %-25s %s\n" \
    "$status_icon" \
    "$agent_status" \
    "$session" \
    "$branch" \
    "$worktree_path"
```

## Agent-Agnostic Design

This design works with any agent CLI tool:
- Detects process name from `$WORKTREE_AGENT_CMD` configuration
- Uses generic activity/CPU metrics, not agent-specific patterns
- Works with claude, gemini, opencode, aider, etc.

## Testing

Test scenarios:
1. Active agent - Launch Claude, give it work, verify `●`
2. Waiting agent - Claude idle at prompt, verify `○`
3. Stopped agent - Kill agent process, verify `◌`
4. No session - Session not running, verify `─`
5. Multiple sessions - Mix of states, verify all correct
6. Different agents - Test with non-claude agent if available

## Trade-offs

**Pros:**
- Simple, non-invasive addition to existing browser
- Works across all agent types
- No continuous monitoring overhead (checks on-demand)
- Familiar interface (builds on existing fzf browser)

**Cons:**
- Activity detection may have false positives (agent outputs but still waiting)
- CPU threshold arbitrary (5% may not fit all agents)
- Requires tmux session to be running (can't check stopped sessions)

## Future Enhancements

- Configurable thresholds via tmux options
- Color-coding for status indicators
- Show time since last activity in preview pane
- Persist agent status in metadata for stopped sessions
