#!/usr/bin/env bash
# tests/test-classifier.sh — Fixture-based tests for _classify_pane_state
# Feeds checked-in pane captures through the pure classifier and asserts
# expected state labels. No tmux, no live agents.
#
# Exit codes: 0 = all passed, 1 = one or more failures

set -euo pipefail

# ---------------------------------------------------------------------------
# Test harness (same as test-unit.sh)
# ---------------------------------------------------------------------------

PASS=0
FAIL=0
SKIP=0

_GREEN='\033[0;32m'
_RED='\033[0;31m'
_YELLOW='\033[1;33m'
_NC='\033[0m'

pass() { echo -e "${_GREEN}PASS${_NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "${_RED}FAIL${_NC} $*"; FAIL=$((FAIL + 1)); }
skip() { echo -e "${_YELLOW}SKIP${_NC} $*"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc — expected $(printf '%q' "$expected"), got $(printf '%q' "$actual")"
    fi
}

# ---------------------------------------------------------------------------
# Load classifier
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures/classifier"

# status-agents.sh sources utils.sh and metadata.sh — make sure they are loadable.
# The script guards its main() with [[ "${BASH_SOURCE[0]}" == "${0}" ]] so sourcing
# is side-effect-free aside from loading the helper libraries.
# shellcheck disable=SC1091
source "$PLUGIN_DIR/scripts/status-agents.sh"

# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

# classify_fixture <fixture-name> <activity_age_seconds> → "waiting"|"not-waiting"
classify_fixture() {
    local fixture="$1" age="$2"
    local now ts last_lines
    now=$(date +%s)
    ts=$((now - age))
    last_lines=$(cat "$FIXTURES/$fixture")
    if _classify_pane_state "$last_lines" "$ts" "$now"; then
        echo "waiting"
    else
        echo "not-waiting"
    fi
}

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

echo ""
echo "=== _classify_pane_state ==="

assert_eq "claude-waiting (stale activity → idle at prompt)"    "waiting"     "$(classify_fixture claude-waiting.txt 30)"
assert_eq "claude-permission (Esc to cancel → blocked)"          "waiting"     "$(classify_fixture claude-permission.txt 0)"
assert_eq "claude-streaming (fresh activity → actively working)" "not-waiting" "$(classify_fixture claude-streaming.txt 2)"
assert_eq "codex-waiting (no esc to interrupt)"                  "waiting"     "$(classify_fixture codex-waiting.txt 30)"
assert_eq "codex-running (esc to interrupt present)"             "not-waiting" "$(classify_fixture codex-running.txt 0)"
assert_eq "plain-shell (no agent UI)"                            "not-waiting" "$(classify_fixture plain-shell.txt 30)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "Classifier tests: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
