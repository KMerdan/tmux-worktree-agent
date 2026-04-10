#!/usr/bin/env bash
# tests/test-e2e-validate.sh — End-to-end tests for the validation pipeline
#
# Creates real git repos, worktrees, metadata, broadcasts, and runs the full
# wta validate / wta merge-check flow. No tmux required (we fake sessions in metadata).
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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        pass "$desc"
    else
        fail "$desc — expected to find $(printf '%q' "$needle") in output"
    fi
}

assert_json_field() {
    local desc="$1" json="$2" field="$3" expected="$4"
    local actual
    actual=$(echo "$json" | jq -r "$field" 2>/dev/null)
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc — $field: expected $(printf '%q' "$expected"), got $(printf '%q' "$actual")"
    fi
}

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TESTS_DIR/.." && pwd)"
WTA="$PLUGIN_DIR/scripts/wta.sh"

export WORKTREE_PLUGIN_DIR="$PLUGIN_DIR"

# Temp dir for all test artifacts
TMPDIR_TEST="$(mktemp -d)"
METADATA_FILE="$TMPDIR_TEST/test-sessions.json"
export METADATA_FILE

cleanup() {
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

# Source libs for metadata setup
source "$PLUGIN_DIR/scripts/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"
source "$PLUGIN_DIR/lib/validate.sh"

echo ""
echo "═══════════════════════════════════════════════"
echo " E2E Validation Pipeline Tests"
echo "═══════════════════════════════════════════════"
echo ""
echo "Temp dir: $TMPDIR_TEST"
echo ""

# ---------------------------------------------------------------------------
# Setup: Create a main repo with branches and worktrees
# ---------------------------------------------------------------------------

MAIN_REPO="$TMPDIR_TEST/main-repo"
WORKTREES_BASE="$TMPDIR_TEST/worktrees"
REPO_NAME="test-project"

git init --quiet "$MAIN_REPO"
(
    cd "$MAIN_REPO"
    git config user.email "test@test.com"
    git config user.name "Test"
    mkdir -p src/auth src/utils src/api
    echo 'export function login() { return true; }' > src/auth/login.ts
    echo 'export function session() { return {}; }' > src/auth/session.ts
    echo 'export function helpers() { return null; }' > src/utils/helpers.ts
    echo 'export function routes() { return []; }' > src/api/routes.ts
    echo '{}' > package.json
    git add -A
    git commit --quiet -m "initial commit"
) 2>/dev/null

# Write a task.md in the main repo
cat > "$MAIN_REPO/task.md" <<'TASKMD'
# Test Project — Development Tasks

**Last Updated**: 2026-04-08

## Project Overview
A test project for validating the wta validation pipeline.

## Shared Constraints
- Do NOT modify `package.json`

---

### Task ID: TASK-AUTH
**Title**: Implement OAuth login
**Status**: `[ ]` pending
**Priority**: P1
**Depends On**: None
**Blocks**: TASK-API

**Scoped Files** (ONLY touch these):
- `src/auth/login.ts` — add OAuth handler
- `src/auth/session.ts` — update session types

**Acceptance Criteria**:
- [ ] OAuth login works

---

### Task ID: TASK-API
**Title**: Add API routes
**Status**: `[ ]` pending
**Priority**: P2
**Depends On**: TASK-AUTH
**Blocks**: None

**Scoped Files** (ONLY touch these):
- `src/api/routes.ts` — add new endpoints
- `src/api/` — new files in api directory

**Acceptance Criteria**:
- [ ] Routes registered
TASKMD

# ---------------------------------------------------------------------------
# Scenario 1: Happy path — agent stays in scope, honest broadcast
# ---------------------------------------------------------------------------
echo "=== Scenario 1: Happy path (all checks should pass) ==="

WT1="$WORKTREES_BASE/$REPO_NAME/task-auth"
mkdir -p "$(dirname "$WT1")"

# Create worktree
(cd "$MAIN_REPO" && git worktree add "$WT1" -b wt/task-auth) >/dev/null 2>&1

# Create .shared
mkdir -p "$WORKTREES_BASE/$REPO_NAME/.shared/broadcasts"
ln -sfn ../.shared "$WT1/.shared"

# Copy task file into worktree (simulating wta spawn)
cat > "$WT1/wt-task-auth.md" <<'EOF'
# Test Project — Development Tasks

**Last Updated**: 2026-04-08

## Project Overview
A test project.

---

### Task ID: TASK-AUTH
**Title**: Implement OAuth login
**Status**: `[ ]` pending
**Priority**: P1
**Depends On**: None
**Blocks**: TASK-API

**Scoped Files** (ONLY touch these):
- `src/auth/login.ts` — add OAuth handler
- `src/auth/session.ts` — update session types

**Acceptance Criteria**:
- [ ] OAuth login works
EOF

# Simulate agent work: modify only in-scope files
(
    cd "$WT1"
    echo 'export function login() { return { oauth: true }; }' > src/auth/login.ts
    echo 'export function session() { return { token: "abc" }; }' > src/auth/session.ts
    git add -A
    git commit --quiet -m "implement OAuth login"
) 2>/dev/null

# Write honest broadcast
cat > "$WORKTREES_BASE/$REPO_NAME/.shared/broadcasts/TASK-AUTH.md" <<'EOF'
# TASK-AUTH — Completed

## Changes Made
- Added OAuth handler to login function
- Updated session to include token

## Impact on Other Tasks
- None — fully independent

## Files Modified
- `src/auth/login.ts`
- `src/auth/session.ts`
EOF

# Register session in metadata
init_metadata
save_session "test-project-task-auth" "$REPO_NAME" "task-auth" "wt/task-auth" \
    "$WT1" "$MAIN_REPO" "false" "Implement OAuth" "claude" "main" ""

# Run validation
result1=$(run_validation_pipeline "test-project-task-auth")

assert_json_field "scenario1: all_pass is true" "$result1" '.all_pass' "true"
assert_json_field "scenario1: scope passes" "$result1" '.checks[] | select(.check=="scope") | .pass' "true"
assert_json_field "scenario1: broadcast passes" "$result1" '.checks[] | select(.check=="broadcast") | .pass' "true"
assert_json_field "scenario1: scope has 0 out_of_scope" "$result1" '.checks[] | select(.check=="scope") | .out_of_scope | length' "0"
assert_json_field "scenario1: broadcast has 0 missing" "$result1" '.checks[] | select(.check=="broadcast") | .missing_from_broadcast | length' "0"

echo ""

# ---------------------------------------------------------------------------
# Scenario 2: Scope violation — agent modifies out-of-scope file
# ---------------------------------------------------------------------------
echo "=== Scenario 2: Scope violation (should fail scope check) ==="

WT2="$WORKTREES_BASE/$REPO_NAME/task-api"
(cd "$MAIN_REPO" && git worktree add "$WT2" -b wt/task-api) >/dev/null 2>&1
ln -sfn ../.shared "$WT2/.shared"

cat > "$WT2/wt-task-api.md" <<'EOF'
# Test Project

---

### Task ID: TASK-API
**Title**: Add API routes
**Status**: `[ ]` pending
**Priority**: P2
**Depends On**: TASK-AUTH
**Blocks**: None

**Scoped Files** (ONLY touch these):
- `src/api/routes.ts` — add new endpoints
- `src/api/` — new files in api directory

**Acceptance Criteria**:
- [ ] Routes registered
EOF

# Agent modifies in-scope file AND out-of-scope file
(
    cd "$WT2"
    echo 'export function routes() { return ["/oauth"]; }' > src/api/routes.ts
    echo 'export function helpers() { return "modified!"; }' > src/utils/helpers.ts  # OUT OF SCOPE
    git add -A
    git commit --quiet -m "add routes + accidentally modify helpers"
) 2>/dev/null

# Write broadcast (honest about the out-of-scope change)
cat > "$WORKTREES_BASE/$REPO_NAME/.shared/broadcasts/TASK-API.md" <<'EOF'
# TASK-API — Completed

## Changes Made
- Added /oauth route
- Also touched helpers (accidentally)

## Impact on Other Tasks
- Modified src/utils/helpers.ts which is shared

## Files Modified
- `src/api/routes.ts`
- `src/utils/helpers.ts`
EOF

save_session "test-project-task-api" "$REPO_NAME" "task-api" "wt/task-api" \
    "$WT2" "$MAIN_REPO" "false" "Add API routes" "claude" "main" ""

result2=$(run_validation_pipeline "test-project-task-api")

assert_json_field "scenario2: all_pass is false" "$result2" '.all_pass' "false"
assert_json_field "scenario2: scope fails" "$result2" '.checks[] | select(.check=="scope") | .pass' "false"
assert_json_field "scenario2: scope detects 1 out-of-scope" "$result2" '.checks[] | select(.check=="scope") | .out_of_scope | length' "1"
assert_contains "scenario2: out-of-scope file is helpers.ts" "src/utils/helpers.ts" \
    "$(echo "$result2" | jq -r '.checks[] | select(.check=="scope") | .out_of_scope[]')"
# Broadcast should still pass (agent was honest)
assert_json_field "scenario2: broadcast passes (honest)" "$result2" '.checks[] | select(.check=="broadcast") | .pass' "true"

echo ""

# ---------------------------------------------------------------------------
# Scenario 3: Dishonest broadcast — agent lies about what they changed
# ---------------------------------------------------------------------------
echo "=== Scenario 3: Dishonest broadcast (should fail broadcast check) ==="

WT3="$WORKTREES_BASE/$REPO_NAME/task-dishonest"
(cd "$MAIN_REPO" && git worktree add "$WT3" -b wt/task-dishonest) >/dev/null 2>&1
ln -sfn ../.shared "$WT3/.shared"

cat > "$WT3/wt-task-dishonest.md" <<'EOF'
# Test Project

---

### Task ID: TASK-DISHONEST
**Title**: Dishonest agent test
**Scoped Files** (ONLY touch these):
- `src/auth/login.ts` — changes
- `src/auth/session.ts` — changes
- `src/utils/helpers.ts` — changes
EOF

# Agent modifies three files
(
    cd "$WT3"
    echo 'export function login() { return "dishonest"; }' > src/auth/login.ts
    echo 'export function session() { return "dishonest"; }' > src/auth/session.ts
    echo 'export function helpers() { return "dishonest"; }' > src/utils/helpers.ts
    git add -A
    git commit --quiet -m "dishonest changes"
) 2>/dev/null

# Broadcast claims only 1 file, and claims a phantom file
cat > "$WORKTREES_BASE/$REPO_NAME/.shared/broadcasts/TASK-DISHONEST.md" <<'EOF'
# TASK-DISHONEST — Completed

## Changes Made
- Updated login

## Files Modified
- `src/auth/login.ts`
- `src/phantom/does-not-exist.ts`
EOF

save_session "test-project-task-dishonest" "$REPO_NAME" "task-dishonest" "wt/task-dishonest" \
    "$WT3" "$MAIN_REPO" "false" "Dishonest test" "claude" "main" ""

result3=$(run_validation_pipeline "test-project-task-dishonest")

assert_json_field "scenario3: all_pass is false" "$result3" '.all_pass' "false"
assert_json_field "scenario3: broadcast fails" "$result3" '.checks[] | select(.check=="broadcast") | .pass' "false"
assert_json_field "scenario3: 2 files missing from broadcast" "$result3" \
    '.checks[] | select(.check=="broadcast") | .missing_from_broadcast | length' "2"
assert_json_field "scenario3: 1 phantom in broadcast" "$result3" \
    '.checks[] | select(.check=="broadcast") | .phantom_in_broadcast | length' "1"
assert_contains "scenario3: phantom file detected" "src/phantom/does-not-exist.ts" \
    "$(echo "$result3" | jq -r '.checks[] | select(.check=="broadcast") | .phantom_in_broadcast[]')"

echo ""

# ---------------------------------------------------------------------------
# Scenario 4: No broadcast file — should fail broadcast check
# ---------------------------------------------------------------------------
echo "=== Scenario 4: Missing broadcast (should fail broadcast check) ==="

WT4="$WORKTREES_BASE/$REPO_NAME/task-nobroadcast"
(cd "$MAIN_REPO" && git worktree add "$WT4" -b wt/task-nobroadcast) >/dev/null 2>&1
ln -sfn ../.shared "$WT4/.shared"

cat > "$WT4/wt-task-nobroadcast.md" <<'EOF'
# Test Project

---

### Task ID: TASK-NOBC
**Title**: No broadcast test
**Scoped Files** (ONLY touch these):
- `src/auth/login.ts` — changes
EOF

(
    cd "$WT4"
    echo 'export function login() { return "nobc"; }' > src/auth/login.ts
    git add -A
    git commit --quiet -m "changes without broadcast"
) 2>/dev/null

# NO broadcast file written

save_session "test-project-task-nobroadcast" "$REPO_NAME" "task-nobroadcast" "wt/task-nobroadcast" \
    "$WT4" "$MAIN_REPO" "false" "No broadcast test" "claude" "main" ""

result4=$(run_validation_pipeline "test-project-task-nobroadcast")

assert_json_field "scenario4: broadcast fails" "$result4" '.checks[] | select(.check=="broadcast") | .pass' "false"
assert_json_field "scenario4: broadcast skipped reason" "$result4" \
    '.checks[] | select(.check=="broadcast") | .skipped' "no broadcast file found"
# Scope should still pass
assert_json_field "scenario4: scope still passes" "$result4" '.checks[] | select(.check=="scope") | .pass' "true"

echo ""

# ---------------------------------------------------------------------------
# Scenario 5: Build/test with .wta/validate.conf
# ---------------------------------------------------------------------------
echo "=== Scenario 5: Build/test checks (with .wta/validate.conf) ==="

# Create validate.conf with a build command that succeeds and test that fails
mkdir -p "$WT1/.wta"
cat > "$WT1/.wta/validate.conf" <<'CONF'
WTA_BUILD_CMD="echo 'build ok'"
WTA_TEST_CMD="echo 'test failed' && exit 1"
WTA_CHECKS="scope,broadcast,build,test"
WTA_CHECK_TIMEOUT=10
CONF

result5=$(run_validation_pipeline "test-project-task-auth")

assert_json_field "scenario5: all_pass is false (test fails)" "$result5" '.all_pass' "false"
assert_json_field "scenario5: build passes" "$result5" '.checks[] | select(.check=="build") | .pass' "true"
assert_json_field "scenario5: test fails" "$result5" '.checks[] | select(.check=="test") | .pass' "false"
assert_json_field "scenario5: test exit code is 1" "$result5" '.checks[] | select(.check=="test") | .exit_code' "1"
assert_contains "scenario5: test output captured" "test failed" \
    "$(echo "$result5" | jq -r '.checks[] | select(.check=="test") | .output_tail')"

# Clean up validate.conf for remaining tests
rm -rf "$WT1/.wta"

echo ""

# ---------------------------------------------------------------------------
# Scenario 6: Graceful degradation — ast-grep/graph skipped when not installed
# ---------------------------------------------------------------------------
echo "=== Scenario 6: Graceful degradation (optional tools) ==="

# Create a validate.conf that enables ast and graph checks
mkdir -p "$WT1/.wta"
cat > "$WT1/.wta/validate.conf" <<'CONF'
WTA_CHECKS="scope,broadcast,ast,graph"
WTA_STRICT_TOOLS=false
CONF

result6=$(run_validation_pipeline "test-project-task-auth")

# Clean up config
rm -rf "$WT1/.wta"

# ast and graph should be skipped gracefully (or run if tools exist)
ast_result=$(echo "$result6" | jq -r '.checks[] | select(.check=="ast")')
graph_result=$(echo "$result6" | jq -r '.checks[] | select(.check=="graph")')

if [ -n "$ast_result" ]; then
    ast_skipped=$(echo "$ast_result" | jq -r '.skipped')
    ast_pass=$(echo "$ast_result" | jq -r '.pass')
    if [ "$ast_skipped" != "null" ] && [ -n "$ast_skipped" ]; then
        pass "scenario6: ast-grep gracefully skipped ($ast_skipped)"
    elif command -v ast-grep &>/dev/null; then
        pass "scenario6: ast-grep installed and ran (pass=$ast_pass)"
    else
        fail "scenario6: ast-grep not installed but wasn't skipped"
    fi
    # Non-strict mode: skipped checks should pass
    assert_eq "scenario6: ast check passes in non-strict mode" "true" "$ast_pass"
else
    fail "scenario6: no ast check result found"
fi

if [ -n "$graph_result" ]; then
    graph_skipped=$(echo "$graph_result" | jq -r '.skipped')
    graph_pass=$(echo "$graph_result" | jq -r '.pass')
    if [ "$graph_skipped" != "null" ] && [ -n "$graph_skipped" ]; then
        pass "scenario6: graph tool gracefully skipped ($graph_skipped)"
    elif command -v madge &>/dev/null; then
        pass "scenario6: madge installed and ran (pass=$graph_pass)"
    else
        fail "scenario6: graph tool not installed but wasn't skipped"
    fi
    assert_eq "scenario6: graph check passes in non-strict mode" "true" "$graph_pass"
else
    fail "scenario6: no graph check result found"
fi

echo ""

# ---------------------------------------------------------------------------
# Scenario 7: Single check mode (--check=scope)
# ---------------------------------------------------------------------------
echo "=== Scenario 7: Single check mode ==="

result7=$(run_validation_pipeline "test-project-task-api" "scope")

check_count=$(echo "$result7" | jq '.checks | length')
assert_eq "scenario7: only 1 check ran" "1" "$check_count"
assert_json_field "scenario7: check is scope" "$result7" '.checks[0].check' "scope"

echo ""

# ---------------------------------------------------------------------------
# Scenario 8: No changes (empty diff)
# ---------------------------------------------------------------------------
echo "=== Scenario 8: No changes (empty diff — no commits on branch) ==="

WT8="$WORKTREES_BASE/$REPO_NAME/task-empty"
(cd "$MAIN_REPO" && git worktree add "$WT8" -b wt/task-empty) >/dev/null 2>&1
ln -sfn ../.shared "$WT8/.shared"

cat > "$WT8/wt-task-empty.md" <<'EOF'
# Test

---

### Task ID: TASK-EMPTY
**Title**: Empty test
**Scoped Files** (ONLY touch these):
- `src/auth/login.ts` — changes
EOF

# No changes made — branch is identical to main

save_session "test-project-task-empty" "$REPO_NAME" "task-empty" "wt/task-empty" \
    "$WT8" "$MAIN_REPO" "false" "Empty test" "claude" "main" ""

result8=$(run_validation_pipeline "test-project-task-empty")

assert_json_field "scenario8: scope passes (no changes)" "$result8" '.checks[] | select(.check=="scope") | .pass' "true"

echo ""

# ---------------------------------------------------------------------------
# Scenario 9: wta.sh CLI integration (run wta validate as subprocess)
# ---------------------------------------------------------------------------
echo "=== Scenario 9: wta CLI integration ==="

# Run wta validate via the actual CLI script
cli_result=$(METADATA_FILE="$METADATA_FILE" WORKTREE_PLUGIN_DIR="$PLUGIN_DIR" \
    bash "$WTA" validate "test-project-task-auth" 2>/dev/null) || true

if [ -n "$cli_result" ]; then
    cli_pass=$(echo "$cli_result" | jq -r '.all_pass' 2>/dev/null)
    assert_eq "scenario9: wta validate CLI returns valid JSON" "true" "$cli_pass"
    assert_contains "scenario9: CLI output has session field" "test-project-task-auth" "$cli_result"
else
    fail "scenario9: wta validate CLI returned no output"
fi

# Run wta validate with --check flag
cli_single=$(METADATA_FILE="$METADATA_FILE" WORKTREE_PLUGIN_DIR="$PLUGIN_DIR" \
    bash "$WTA" validate "test-project-task-auth" --check=scope 2>/dev/null) || true

if [ -n "$cli_single" ]; then
    single_count=$(echo "$cli_single" | jq '.checks | length' 2>/dev/null)
    assert_eq "scenario9: wta validate --check=scope runs 1 check" "1" "$single_count"
else
    fail "scenario9: wta validate --check=scope returned no output"
fi

# Run wta validate on scope-violating session (should exit non-zero)
if METADATA_FILE="$METADATA_FILE" WORKTREE_PLUGIN_DIR="$PLUGIN_DIR" \
    bash "$WTA" validate "test-project-task-api" >/dev/null 2>&1; then
    fail "scenario9: wta validate should exit non-zero on failure"
else
    pass "scenario9: wta validate exits non-zero on scope violation"
fi

echo ""

# ---------------------------------------------------------------------------
# Scenario 10: extract_scoped_files end-to-end (from real task.md)
# ---------------------------------------------------------------------------
echo "=== Scenario 10: Scoped files extraction from real task.md ==="

# Parse the main repo's task.md
task_data=$(parse_tasks "$MAIN_REPO/task.md")

# Get TASK-AUTH line numbers
auth_line=$(echo "$task_data" | grep "^TASK-AUTH")
auth_start=$(echo "$auth_line" | cut -f7)
auth_end=$(echo "$auth_line" | cut -f8)

auth_scoped=$(extract_scoped_files "$MAIN_REPO/task.md" "$auth_start" "$auth_end")
assert_contains "scenario10: TASK-AUTH scoped has login.ts" "src/auth/login.ts" "$auth_scoped"
assert_contains "scenario10: TASK-AUTH scoped has session.ts" "src/auth/session.ts" "$auth_scoped"

auth_count=$(echo "$auth_scoped" | grep -c . || true)
assert_eq "scenario10: TASK-AUTH has 2 scoped files" "2" "$auth_count"

# Get TASK-API line numbers
api_line=$(echo "$task_data" | grep "^TASK-API")
api_start=$(echo "$api_line" | cut -f7)
api_end=$(echo "$api_line" | cut -f8)

api_scoped=$(extract_scoped_files "$MAIN_REPO/task.md" "$api_start" "$api_end")
assert_contains "scenario10: TASK-API scoped has routes.ts" "src/api/routes.ts" "$api_scoped"
assert_contains "scenario10: TASK-API scoped has api dir" "src/api/" "$api_scoped"

echo ""

# ---------------------------------------------------------------------------
# Scenario 11: Scaffolding filter retains tracked project files
# ---------------------------------------------------------------------------
# Regression test for a bug where _filter_scaffolding stripped CLAUDE.md /
# AGENTS.md / wt-*.md / .shared/* / .wta/* by name alone, silently hiding
# modifications to project files whose names happened to collide with
# scaffolding patterns (e.g. this very plugin has a tracked CLAUDE.md).
# The fix: tracked files in parent_branch must always be visible to
# check_scope and check_broadcast.
echo "=== Scenario 11: Scaffolding filter retains tracked project files ==="

SCAFF_REPO="$TMPDIR_TEST/scaff-repo"
SCAFF_WORKTREES="$TMPDIR_TEST/scaff-worktrees/scaff-project"
mkdir -p "$SCAFF_WORKTREES"

git init --quiet "$SCAFF_REPO"
(
    cd "$SCAFF_REPO"
    git config user.email "wta-test@local"
    git config user.name "wta-test"
    # Tracked CLAUDE.md at the project root — a real project file, not scaffolding
    echo "# Test Project" > CLAUDE.md
    git add CLAUDE.md
    git commit --quiet -m "initial: add project CLAUDE.md"
) 2>/dev/null

WT11="$SCAFF_WORKTREES/scaffolding-test"
(cd "$SCAFF_REPO" && git worktree add "$WT11" -b wt/scaffolding-test) >/dev/null 2>&1

# Set up .shared broadcasts directory for this project (sibling of worktree)
mkdir -p "$SCAFF_WORKTREES/.shared/broadcasts"
ln -sfn ../.shared "$WT11/.shared"

# Agent modifies the tracked CLAUDE.md AND adds a new source file
(
    cd "$WT11"
    mkdir -p src
    echo "" >> CLAUDE.md
    echo "## Updated by agent" >> CLAUDE.md
    echo 'export const feature = true;' > src/feature.ts
    git add -A
    git commit --quiet -m "update docs and add feature"
) 2>/dev/null

# Task file scoping both files (the key scenario: CLAUDE.md is legit in-scope)
cat > "$WT11/wt-scaffolding-test.md" <<'EOF'
# Scaffolding Test

---

### Task ID: TASK-scaffolding-test
**Title**: Update project docs and add feature
**Scoped Files** (ONLY touch these):
- `CLAUDE.md` — document new feature
- `src/feature.ts` — new feature implementation
EOF

# Broadcast claims both files. Filename must be discoverable by
# _find_broadcast_file, which matches basename against the session topic
# (lowercase, whitespace-stripped).
cat > "$SCAFF_WORKTREES/.shared/broadcasts/scaffolding-test.md" <<'EOF'
# TASK-scaffolding-test — Completed

## Changes Made
- Updated project CLAUDE.md with new section
- Added src/feature.ts

## Files Modified
- `CLAUDE.md`
- `src/feature.ts`
EOF

save_session "scaff-project-scaffolding-test" "scaff-project" "scaffolding-test" \
    "wt/scaffolding-test" "$WT11" "$SCAFF_REPO" "false" "Scaffolding filter test" \
    "claude" "main" ""

result11=$(run_validation_pipeline "scaff-project-scaffolding-test")

assert_json_field "scenario11: all_pass is true" "$result11" '.all_pass' "true"
assert_json_field "scenario11: scope passes" "$result11" \
    '.checks[] | select(.check=="scope") | .pass' "true"
assert_json_field "scenario11: broadcast passes" "$result11" \
    '.checks[] | select(.check=="broadcast") | .pass' "true"

# The critical assertions: tracked CLAUDE.md must be visible to both checks.
# Before the fix, _filter_scaffolding would strip it by name alone and both
# arrays would be missing it (scope would show untouched_scope for CLAUDE.md
# and broadcast would report it as a phantom claim).
scope_in_scope11=$(echo "$result11" | jq -r '.checks[] | select(.check=="scope") | .in_scope[]')
assert_contains "scenario11: scope.in_scope contains tracked CLAUDE.md" \
    "CLAUDE.md" "$scope_in_scope11"
assert_contains "scenario11: scope.in_scope contains src/feature.ts" \
    "src/feature.ts" "$scope_in_scope11"

bcast_actual11=$(echo "$result11" | jq -r '.checks[] | select(.check=="broadcast") | .actual[]')
assert_contains "scenario11: broadcast.actual contains tracked CLAUDE.md" \
    "CLAUDE.md" "$bcast_actual11"
assert_contains "scenario11: broadcast.actual contains src/feature.ts" \
    "src/feature.ts" "$bcast_actual11"

echo ""

# ---------------------------------------------------------------------------
# Scenario 12: Three-dot diff stability under parent advance
# ---------------------------------------------------------------------------
# Regression test: a session branched from main at commit X should not be
# polluted when main later advances with unrelated commits. The validation
# pipeline relies on `git diff parent_branch...HEAD` (three-dot) which diffs
# from the merge base; a two-dot diff would leak the parent's new commits
# into both in_scope / out_of_scope and broadcast.actual.
echo "=== Scenario 12: Three-dot diff stability under parent advance ==="

ADV_REPO="$TMPDIR_TEST/advance-repo"
ADV_WORKTREES="$TMPDIR_TEST/advance-worktrees/advance-project"
mkdir -p "$ADV_WORKTREES"

git init --quiet "$ADV_REPO"
(
    cd "$ADV_REPO"
    git config user.email "wta-test@local"
    git config user.name "wta-test"
    echo 'export const base = 1;' > base.ts
    git add base.ts
    git commit --quiet -m "initial"
) 2>/dev/null

WT12="$ADV_WORKTREES/parent-advance"
(cd "$ADV_REPO" && git worktree add "$WT12" -b wt/parent-advance) >/dev/null 2>&1

mkdir -p "$ADV_WORKTREES/.shared/broadcasts"
ln -sfn ../.shared "$WT12/.shared"

# Session commits its own file
(
    cd "$WT12"
    echo 'export const sessionWork = true;' > session-work.ts
    git add session-work.ts
    git commit --quiet -m "session work"
) 2>/dev/null

# Now advance main with an unrelated commit — main is ahead of the session's
# branch point, but the session branch itself is unchanged.
(
    cd "$ADV_REPO"
    echo 'export const parentAdvance = true;' > parent-advance.ts
    git add parent-advance.ts
    git commit --quiet -m "unrelated parent advance"
) 2>/dev/null

cat > "$WT12/wt-parent-advance.md" <<'EOF'
# Parent Advance Test

---

### Task ID: TASK-parent-advance
**Title**: Session work
**Scoped Files** (ONLY touch these):
- `session-work.ts` — new session file
EOF

cat > "$ADV_WORKTREES/.shared/broadcasts/parent-advance.md" <<'EOF'
# TASK-parent-advance — Completed

## Changes Made
- Added session-work.ts

## Files Modified
- `session-work.ts`
EOF

save_session "advance-project-parent-advance" "advance-project" "parent-advance" \
    "wt/parent-advance" "$WT12" "$ADV_REPO" "false" "Parent advance test" \
    "claude" "main" ""

result12=$(run_validation_pipeline "advance-project-parent-advance")

assert_json_field "scenario12: all_pass is true" "$result12" '.all_pass' "true"
assert_json_field "scenario12: scope passes" "$result12" \
    '.checks[] | select(.check=="scope") | .pass' "true"
assert_json_field "scenario12: broadcast passes" "$result12" \
    '.checks[] | select(.check=="broadcast") | .pass' "true"

# in_scope must contain session-work.ts and NOT contain parent-advance.ts
scope_in_scope12=$(echo "$result12" | jq -r '.checks[] | select(.check=="scope") | .in_scope[]')
assert_contains "scenario12: scope.in_scope contains session-work.ts" \
    "session-work.ts" "$scope_in_scope12"
if echo "$scope_in_scope12" | grep -qFx "parent-advance.ts"; then
    fail "scenario12: scope.in_scope must NOT contain parent-advance.ts (parent leak)"
else
    pass "scenario12: scope.in_scope excludes parent-advance.ts"
fi

# The parent advance file must not surface as out_of_scope either — it belongs
# to the parent branch, not to the session's diff.
scope_oos12=$(echo "$result12" | jq -r '.checks[] | select(.check=="scope") | .out_of_scope[]')
if echo "$scope_oos12" | grep -qFx "parent-advance.ts"; then
    fail "scenario12: scope.out_of_scope must NOT contain parent-advance.ts (parent leak)"
else
    pass "scenario12: scope.out_of_scope excludes parent-advance.ts"
fi

# broadcast.actual must be session-work.ts only
bcast_actual12=$(echo "$result12" | jq -r '.checks[] | select(.check=="broadcast") | .actual[]')
assert_contains "scenario12: broadcast.actual contains session-work.ts" \
    "session-work.ts" "$bcast_actual12"
if echo "$bcast_actual12" | grep -qFx "parent-advance.ts"; then
    fail "scenario12: broadcast.actual must NOT contain parent-advance.ts (parent leak)"
else
    pass "scenario12: broadcast.actual excludes parent-advance.ts"
fi

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "═══════════════════════════════════════════════"
echo " Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "═══════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
