#!/usr/bin/env bash
# tests/test-static.sh — Static analysis for tmux-worktree-agent
# Checks: syntax validity, /dev/tty discipline, no hardcoded "main" branch,
#         referenced scripts exist.
#
# Exit codes: 0 = all passed, 1 = one or more failures
# No tmux, git, or live processes required.

set -euo pipefail

PASS=0
FAIL=0

_GREEN='\033[0;32m'
_RED='\033[0;31m'
_NC='\033[0m'

pass() { echo -e "${_GREEN}PASS${_NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "${_RED}FAIL${_NC} $*"; FAIL=$((FAIL + 1)); }

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Gather all shell scripts
# ---------------------------------------------------------------------------

ALL_SCRIPTS=()
while IFS= read -r f; do
    ALL_SCRIPTS+=("$f")
done < <(find "$PLUGIN_DIR/scripts" "$PLUGIN_DIR/lib" -maxdepth 1 -name "*.sh" -type f | sort)
ALL_SCRIPTS+=("$PLUGIN_DIR/worktree-agent.tmux")

# ---------------------------------------------------------------------------
# Check 1: Bash syntax validity
# ---------------------------------------------------------------------------
echo ""
echo "=== Syntax check (bash -n) ==="

for script in "${ALL_SCRIPTS[@]}"; do
    rel="${script#$PLUGIN_DIR/}"
    if bash -n "$script" 2>/dev/null; then
        pass "syntax OK: $rel"
    else
        err_msg="$(bash -n "$script" 2>&1 | head -3)"
        fail "syntax error: $rel — $err_msg"
    fi
done

# ---------------------------------------------------------------------------
# Check 2: No bare read -r without /dev/tty in interactive scripts
# ---------------------------------------------------------------------------
echo ""
echo "=== /dev/tty discipline ==="

# Interactive scripts are those launched via display-popup in worktree-agent.tmux
INTERACTIVE_SCRIPTS=(
    "$PLUGIN_DIR/scripts/browse-sessions.sh"
    "$PLUGIN_DIR/scripts/create-worktree.sh"
    "$PLUGIN_DIR/scripts/kill-worktree.sh"
    "$PLUGIN_DIR/scripts/reconcile.sh"
    "$PLUGIN_DIR/scripts/register-session.sh"
    "$PLUGIN_DIR/scripts/session-description.sh"
    "$PLUGIN_DIR/scripts/merge-orchestrator.sh"
)

for script in "${INTERACTIVE_SCRIPTS[@]}"; do
    [ -f "$script" ] || continue
    rel="${script#$PLUGIN_DIR/}"

    # Find read -r / read -n calls that are NOT in while loops and NOT redirected from /dev/tty
    offending="$(grep -n '\bread -[rn]' "$script" \
        | grep -v '</dev/tty' \
        | grep -v '< /dev/tty' \
        | grep -v '^\s*#' \
        | grep -v 'while' \
        | grep -v 'done' \
        | grep -v '<<<' \
        || true)"

    if [ -z "$offending" ]; then
        pass "/dev/tty discipline: $rel"
    else
        while IFS= read -r line; do
            fail "/dev/tty discipline: $rel — bare read: $line"
        done <<< "$offending"
    fi
done

# ---------------------------------------------------------------------------
# Check 3: No hardcoded "main" as a branch reference in git commands
# ---------------------------------------------------------------------------
echo ""
echo "=== No hardcoded branch name 'main' in git commands ==="

# We specifically look for git commands that reference "main" as a branch
# Exclude utils.sh (owns the deliberate fallback in get_default_branch)
BRANCH_CHECK_SCRIPTS=()
while IFS= read -r f; do
    BRANCH_CHECK_SCRIPTS+=("$f")
done < <(find "$PLUGIN_DIR/scripts" "$PLUGIN_DIR/lib" -maxdepth 1 -name "*.sh" -type f | grep -v 'utils\.sh' | sort)

for script in "${BRANCH_CHECK_SCRIPTS[@]}"; do
    rel="${script#$PLUGIN_DIR/}"

    # Look for git commands that use literal "main" as a branch ref
    offending="$(grep -nE 'git.*(log|diff|merge|branch|checkout|rebase|cherry-pick).*\bmain\b' "$script" \
        | grep -v '^\s*#' \
        | grep -v 'main()' \
        | grep -v 'main_repo' \
        | grep -v '\$.*main' \
        | grep -v '\${.*main' \
        || true)"

    if [ -z "$offending" ]; then
        pass "no hardcoded 'main' in git commands: $rel"
    else
        while IFS= read -r line; do
            fail "hardcoded 'main' branch: $rel — $line"
        done <<< "$offending"
    fi
done

# ---------------------------------------------------------------------------
# Check 4: All scripts referenced in worktree-agent.tmux actually exist
# ---------------------------------------------------------------------------
echo ""
echo "=== Referenced scripts exist ==="

ENTRY_POINT="$PLUGIN_DIR/worktree-agent.tmux"

REFERENCED_PATHS=()
while IFS= read -r f; do
    REFERENCED_PATHS+=("$f")
done < <(grep -oE '\$\{?CURRENT_DIR\}?/(scripts|lib)/[A-Za-z0-9_.-]+' "$ENTRY_POINT" \
    | sed 's|\${CURRENT_DIR}|'"$PLUGIN_DIR"'|g; s|\$CURRENT_DIR|'"$PLUGIN_DIR"'|g' \
    | sort -u)

for ref_path in "${REFERENCED_PATHS[@]}"; do
    rel="${ref_path#$PLUGIN_DIR/}"
    if [ -f "$ref_path" ]; then
        pass "referenced file exists: $rel"
    else
        fail "referenced file missing: $rel"
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "======================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "======================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
