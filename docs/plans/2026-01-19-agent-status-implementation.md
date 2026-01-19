# Agent Status Indicators Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add real-time agent status indicators to the fzf session browser showing which sessions have agents actively working vs waiting for input.

**Architecture:** Enhance `scripts/browse-sessions.sh` with agent detection logic that checks process existence, pane activity, and CPU usage to determine agent state. Display status as additional column in fzf list.

**Tech Stack:** Bash, tmux, fzf, ps, pgrep

---

## Task 1: Add Agent Status Detection Function

**Files:**
- Modify: `scripts/browse-sessions.sh:80` (after generate_preview function)

**Step 1: Add get_agent_status() function**

Insert after line 80 (after generate_preview function closes):

```bash
# Get agent status for a session
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

**Step 2: Verify syntax**

Run: `bash -n scripts/browse-sessions.sh`
Expected: No output (syntax OK)

**Step 3: Commit**

```bash
git add scripts/browse-sessions.sh
git commit -m "feat: add agent status detection function"
```

---

## Task 2: Integrate Agent Status into Session List

**Files:**
- Modify: `scripts/browse-sessions.sh:129-136` (build_session_list function)

**Step 1: Add agent status variable after session status determination**

After line 129 (after status_icon is set), add:

```bash
        # Get agent status
        local agent_status="─"
        if $session_exists; then
            agent_status=$(get_agent_status "$session")
        fi
```

**Step 2: Update printf to include agent status**

Replace line 132-136 with:

```bash
        # Format: session_status agent_status session branch path
        printf "%-2s %-2s %-30s %-25s %s\n" \
            "$status_icon" \
            "$agent_status" \
            "$session" \
            "$branch" \
            "$worktree_path"
```

**Step 3: Verify syntax**

Run: `bash -n scripts/browse-sessions.sh`
Expected: No output (syntax OK)

**Step 4: Commit**

```bash
git add scripts/browse-sessions.sh
git commit -m "feat: integrate agent status into session list display"
```

---

## Task 3: Update FZF Header

**Files:**
- Modify: `scripts/browse-sessions.sh:164` (fzf header line)

**Step 1: Update header to mention agent status**

Replace line 164 with:

```bash
        --header="Worktree Sessions ($(count_sessions) active) | [S][A] Session+Agent Status | Enter: switch | Ctrl-d: delete | Tab: preview" \
```

**Step 2: Verify syntax**

Run: `bash -n scripts/browse-sessions.sh`
Expected: No output (syntax OK)

**Step 3: Commit**

```bash
git add scripts/browse-sessions.sh
git commit -m "docs: update fzf header to explain agent status column"
```

---

## Task 4: Manual Testing

**Files:**
- Test: `scripts/browse-sessions.sh` (manual interactive testing)

**Step 1: Reload tmux configuration**

Run: `tmux source-file ~/.tmux.conf`
Expected: Plugin reloaded

**Step 2: Test with active agent**

Setup:
1. Ensure current session has Claude running
2. Give Claude a task that takes a few seconds

Run: `prefix + w`
Expected: Current session shows `● ●` (session active, agent working)

**Step 3: Test with idle agent**

Setup:
1. Wait for Claude to finish and show prompt
2. Don't type anything (let it idle)

Run: `prefix + w`
Expected: Current session shows `● ○` (session active, agent waiting)

**Step 4: Test with stopped agent**

Setup:
1. Kill Claude process manually (find PID and kill)

Run: `prefix + w`
Expected: Current session shows `● ◌` (session active, agent stopped)

**Step 5: Test with no session**

Setup:
1. Switch to different session
2. Browse sessions

Expected: Stopped sessions show `○ ─` (worktree only, no session)

**Step 6: Document test results**

Create test log:
```bash
echo "# Manual Test Results - $(date)" >> docs/test-log.md
echo "- Active agent: [PASS/FAIL]" >> docs/test-log.md
echo "- Idle agent: [PASS/FAIL]" >> docs/test-log.md
echo "- Stopped agent: [PASS/FAIL]" >> docs/test-log.md
echo "- No session: [PASS/FAIL]" >> docs/test-log.md
```

**Step 7: Commit test log**

```bash
git add docs/test-log.md
git commit -m "test: document agent status indicator manual tests"
```

---

## Task 5: Update Documentation

**Files:**
- Modify: `CLAUDE.md` (add agent status feature documentation)
- Modify: `README.md` (update browser interface section)

**Step 1: Update CLAUDE.md**

In the "Workflows" section, update `scripts/browse-sessions.sh` description (around line 56):

```markdown
**scripts/browse-sessions.sh** - fzf browser for sessions
- Status indicators:
  - Session: ● (active), ○ (worktree only), ⚠ (session only), ✗ (stale)
  - Agent: ● (working), ○ (waiting), ◌ (stopped), ─ (N/A)
- Auto-cleanup of stale metadata on launch
- Preview pane shows: session info, active windows, git status
- Actions: Enter (switch), Ctrl-d (delete), Ctrl-r (refresh), Tab (toggle preview)
- Runs in tmux popup if tmux >= 3.2, otherwise splits
```

**Step 2: Update README.md**

In the "Browser Interface" section (around line 147), update the list view description:

```markdown
**List View:**
- Session Status:
  - `●` - Active session (session + worktree exist)
  - `○` - Worktree only (no session running)
  - `⚠` - Session only (worktree deleted)
  - `✗` - Stale (both missing, will be cleaned)
- Agent Status:
  - `●` - Agent actively working (recent output + CPU)
  - `○` - Agent waiting for input (idle)
  - `◌` - Agent stopped (no process)
  - `─` - N/A (session not running)
```

**Step 3: Verify documentation accuracy**

Run: `cat CLAUDE.md | grep -A 10 "browse-sessions"`
Expected: Shows updated description

Run: `cat README.md | grep -A 15 "List View"`
Expected: Shows agent status indicators

**Step 4: Commit documentation**

```bash
git add CLAUDE.md README.md
git commit -m "docs: document agent status indicators feature"
```

---

## Task 6: Final Verification and Cleanup

**Files:**
- Review: All modified files

**Step 1: Review all changes**

Run: `git diff main..HEAD --stat`
Expected: Shows modified files:
- scripts/browse-sessions.sh
- CLAUDE.md
- README.md
- docs/plans/2026-01-19-agent-status-implementation.md
- docs/test-log.md (if created)

**Step 2: Full integration test**

Setup: Create 3 worktree sessions with different states
Run: `prefix + w`
Expected: All sessions show correct status indicators

**Step 3: Check for shell errors**

Run: `shellcheck scripts/browse-sessions.sh`
Expected: No errors (or only minor warnings)

**Step 4: Create summary commit if needed**

If any final tweaks were made:
```bash
git add -A
git commit -m "chore: final cleanup for agent status feature"
```

---

## Success Criteria

- [ ] Agent status function added to browse-sessions.sh
- [ ] Session list displays both session and agent status
- [ ] All 4 agent states (●○◌─) work correctly
- [ ] FZF header explains status columns
- [ ] Manual tests pass for all scenarios
- [ ] Documentation updated in CLAUDE.md and README.md
- [ ] No shell syntax errors
- [ ] Feature works with claude and other agents

## Testing Commands Summary

```bash
# Syntax check
bash -n scripts/browse-sessions.sh

# Reload plugin
tmux source-file ~/.tmux.conf

# Open browser
prefix + w

# Shellcheck (optional)
shellcheck scripts/browse-sessions.sh
```

## Notes

- Agent detection is process-based, works with any CLI agent
- Thresholds: 15s activity window, 5% CPU for "working" state
- Future: Make thresholds configurable via tmux options
- pgrep may not find deeply nested processes - acceptable trade-off
