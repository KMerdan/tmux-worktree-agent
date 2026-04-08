#!/usr/bin/env bash
# tests/test-unit.sh — Unit tests for tmux-worktree-agent
# Tests pure functions in isolation: no tmux, no git worktrees, no live processes.
# Run from anywhere; relies only on bash, jq, git (for get_default_branch git-config path).
#
# Exit codes: 0 = all passed, 1 = one or more failures

set -euo pipefail

# ---------------------------------------------------------------------------
# Test harness
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

assert_empty() {
    local desc="$1" actual="$2"
    if [ -z "$actual" ]; then
        pass "$desc"
    else
        fail "$desc — expected empty, got $(printf '%q' "$actual")"
    fi
}

assert_nonempty() {
    local desc="$1" actual="$2"
    if [ -n "$actual" ]; then
        pass "$desc"
    else
        fail "$desc — expected non-empty output"
    fi
}

assert_exit0() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc — command exited non-zero"
    fi
}

assert_exit_nonzero() {
    local desc="$1"
    shift
    if ! "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc — command exited 0, expected failure"
    fi
}

# ---------------------------------------------------------------------------
# Bootstrap: source libraries under test
# ---------------------------------------------------------------------------

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# Override plugin dir so library internals resolve paths correctly
export WORKTREE_PLUGIN_DIR="$PLUGIN_DIR"

source "$PLUGIN_DIR/scripts/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"
source "$PLUGIN_DIR/lib/task-parser.sh"

# Redirect all metadata I/O to a temp file so tests never touch the real store
TMPDIR_TEST="$(mktemp -d)"
METADATA_FILE="$TMPDIR_TEST/test-sessions.json"
export METADATA_FILE

cleanup() {
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Section 1: sanitize_name
# ---------------------------------------------------------------------------
echo ""
echo "=== sanitize_name ==="

assert_eq "slash becomes hyphen"          "feature-login"       "$(sanitize_name "feature/login")"
assert_eq "double slash"                  "a-b-c"               "$(sanitize_name "a/b/c")"
assert_eq "uppercase becomes lowercase"   "myfeature"           "$(sanitize_name "MyFeature")"
assert_eq "spaces are removed"            "fixbug"              "$(sanitize_name "fix bug")"
assert_eq "mixed: slash+space+upper"      "fix-thebug"          "$(sanitize_name "Fix/the bug")"
assert_eq "already clean passthrough"     "clean-name"          "$(sanitize_name "clean-name")"
assert_eq "digits preserved"              "task-123"            "$(sanitize_name "task/123")"

# ---------------------------------------------------------------------------
# Section 2: expand_tilde
# ---------------------------------------------------------------------------
echo ""
echo "=== expand_tilde ==="

assert_eq "~/foo/bar expands"             "$HOME/foo/bar"       "$(expand_tilde "~/foo/bar")"
assert_eq "no tilde unchanged"            "/abs/path"           "$(expand_tilde "/abs/path")"
assert_eq "empty string unchanged"        ""                    "$(expand_tilde "")"
assert_eq "tilde alone"                   "$HOME"               "$(expand_tilde "~")"
assert_eq "tilde not at start unchanged"  "/a/~/b"              "$(expand_tilde "/a/~/b")"

# ---------------------------------------------------------------------------
# Section 3: generate_session_name
# ---------------------------------------------------------------------------
echo ""
echo "=== generate_session_name ==="

assert_eq "repo-topic format"             "myrepo-mybranch"     "$(generate_session_name "myrepo" "mybranch")"
assert_eq "hyphens in both parts"         "my-repo-my-topic"    "$(generate_session_name "my-repo" "my-topic")"

# ---------------------------------------------------------------------------
# Section 4: get_default_branch — fallback chain
# ---------------------------------------------------------------------------
echo ""
echo "=== get_default_branch ==="

# Case A: a real git repo with remote HEAD set
GITDIR="$TMPDIR_TEST/testrepo"
ORIGINDIR="$TMPDIR_TEST/origin.git"

git init --quiet "$GITDIR"
git init --bare --quiet "$ORIGINDIR"

(
    cd "$GITDIR"
    git config user.email "test@test.com"
    git config user.name "Test"
    git checkout -b trunk >/dev/null 2>&1 || git checkout -b trunk
    echo "init" > README
    git add README
    git commit --quiet -m "init"
    git remote add origin "$ORIGINDIR"
    git push --quiet origin trunk
    git remote set-head origin trunk
) 2>/dev/null

branch_from_remote="$(get_default_branch "$GITDIR")"
assert_eq "get_default_branch uses remote HEAD" "trunk" "$branch_from_remote"

# Case B: no remote HEAD — falls back to git config init.defaultBranch
GITDIR2="$TMPDIR_TEST/testrepo2"
git init --quiet "$GITDIR2" 2>/dev/null
(
    cd "$GITDIR2"
    git config user.email "test@test.com"
    git config user.name "Test"
) 2>/dev/null

_ORIG_GIT_CONFIG="${GIT_CONFIG_GLOBAL:-}"
_FAKE_GIT_CONFIG="$TMPDIR_TEST/fake-gitconfig"
cat > "$_FAKE_GIT_CONFIG" <<'EOF'
[init]
    defaultBranch = develop
EOF
export GIT_CONFIG_GLOBAL="$_FAKE_GIT_CONFIG"

branch_from_config="$(get_default_branch "$GITDIR2")"
assert_eq "get_default_branch falls back to global config" "develop" "$branch_from_config"

# Case C: no remote, no global config — hardcoded "main"
_EMPTY_GIT_CONFIG="$TMPDIR_TEST/empty-gitconfig"
touch "$_EMPTY_GIT_CONFIG"
export GIT_CONFIG_GLOBAL="$_EMPTY_GIT_CONFIG"

GITDIR3="$TMPDIR_TEST/testrepo3"
git init --quiet "$GITDIR3" 2>/dev/null

branch_hardcoded="$(get_default_branch "$GITDIR3")"
assert_eq "get_default_branch hardcoded fallback is main" "main" "$branch_hardcoded"

# Restore GIT_CONFIG_GLOBAL
if [ -z "$_ORIG_GIT_CONFIG" ]; then
    unset GIT_CONFIG_GLOBAL
else
    export GIT_CONFIG_GLOBAL="$_ORIG_GIT_CONFIG"
fi

# ---------------------------------------------------------------------------
# Section 5: Metadata CRUD
# ---------------------------------------------------------------------------
echo ""
echo "=== metadata CRUD ==="

rm -f "$METADATA_FILE"

save_session "myrepo-feat" "myrepo" "feat" "wt/feat" \
    "/home/user/.worktrees/myrepo/feat" "/home/user/projects/myrepo" \
    "false" "My feature description" "claude" "dev/feature-v2" "myrepo-main"

sessions_list="$(list_sessions)"
assert_contains "list_sessions contains saved session" "myrepo-feat" "$sessions_list"

field_repo="$(get_session_field "myrepo-feat" "repo")"
assert_eq "get_session_field repo" "myrepo" "$field_repo"

field_branch="$(get_session_field "myrepo-feat" "branch")"
assert_eq "get_session_field branch" "wt/feat" "$field_branch"

field_topic="$(get_session_field "myrepo-feat" "topic")"
assert_eq "get_session_field topic" "feat" "$field_topic"

field_desc="$(get_session_field "myrepo-feat" "description")"
assert_eq "get_session_field description" "My feature description" "$field_desc"

field_agent="$(get_session_field "myrepo-feat" "agent_cmd")"
assert_eq "get_session_field agent_cmd" "claude" "$field_agent"

field_parent="$(get_session_field "myrepo-feat" "parent_branch")"
assert_eq "get_session_field parent_branch" "dev/feature-v2" "$field_parent"

field_parent_sess="$(get_session_field "myrepo-feat" "parent_session")"
assert_eq "get_session_field parent_session" "myrepo-main" "$field_parent_sess"

nonexistent_field="$(get_session_field "does-not-exist" "repo")"
assert_empty "get_session_field nonexistent returns empty" "$nonexistent_field"

if session_in_metadata "myrepo-feat"; then
    pass "session_in_metadata true for existing session"
else
    fail "session_in_metadata should return true for existing session"
fi

if ! session_in_metadata "ghost-session"; then
    pass "session_in_metadata false for missing session"
else
    fail "session_in_metadata should return false for missing session"
fi

save_session "myrepo-bugfix" "myrepo" "bugfix" "wt/bugfix" \
    "/home/user/.worktrees/myrepo/bugfix" "/home/user/projects/myrepo" \
    "true" "" "codex"

field_parent_empty="$(get_session_field "myrepo-bugfix" "parent_branch")"
assert_eq "get_session_field parent_branch empty when not provided" "" "$field_parent_empty"

field_parent_sess_empty="$(get_session_field "myrepo-bugfix" "parent_session")"
assert_eq "get_session_field parent_session empty when not provided" "" "$field_parent_sess_empty"

count="$(count_sessions)"
assert_eq "count_sessions returns 2" "2" "$count"

found_by_path="$(find_session_by_path "/home/user/.worktrees/myrepo/feat")"
assert_eq "find_session_by_path" "myrepo-feat" "$found_by_path"

repo_sessions="$(find_sessions_by_repo "myrepo")"
assert_contains "find_sessions_by_repo includes feat" "myrepo-feat" "$repo_sessions"
assert_contains "find_sessions_by_repo includes bugfix" "myrepo-bugfix" "$repo_sessions"

update_session_description "myrepo-feat" "Updated description"
updated_desc="$(get_session_field "myrepo-feat" "description")"
assert_eq "update_session_description" "Updated description" "$updated_desc"

agent="$(get_session_agent "myrepo-bugfix")"
assert_eq "get_session_agent" "codex" "$agent"

delete_session "myrepo-feat"
remaining="$(list_sessions)"
if echo "$remaining" | grep -q "myrepo-feat"; then
    fail "delete_session — deleted session still present"
else
    pass "delete_session removes session"
fi

count_after="$(count_sessions)"
assert_eq "count_sessions after delete is 1" "1" "$count_after"

delete_session "ghost-session"
pass "delete_session nonexistent is a no-op"

rm -f "$METADATA_FILE"
init_metadata
assert_exit0 "init_metadata creates valid JSON" jq '.' "$METADATA_FILE"
empty_count="$(count_sessions)"
assert_eq "fresh metadata has 0 sessions" "0" "$empty_count"

# ---------------------------------------------------------------------------
# Section 6: parse_tasks from lib/task-parser.sh
# ---------------------------------------------------------------------------
echo ""
echo "=== parse_tasks ==="

TASK_FILE="$TMPDIR_TEST/sample-tasks.md"

cat > "$TASK_FILE" <<'EOF'
# Preamble

This is shared context before the first separator.

---

### Task ID: TASK-001
**Title**: Add login endpoint
**Status**: `[ ]` pending
**Priority**: P1
**Depends On**: None
**Blocks**: TASK-002

Implement the /login REST endpoint.

---

### Task ID: TASK-002
**Title**: Add session middleware
**Status**: `[ ]` pending
**Priority**: P2
**Depends On**: TASK-001
**Blocks**: None

Implement session validation middleware.

---

### Task ID: TASK-003
**Title**: Write integration tests
**Priority**: P3

No status or depends fields — optional fields absent.
EOF

parse_out="$(parse_tasks "$TASK_FILE")"

task_count="$(echo "$parse_out" | wc -l | tr -d '[:space:]')"
assert_eq "parse_tasks finds 3 tasks" "3" "$task_count"

assert_contains "parse_tasks extracts TASK-001" "TASK-001" "$parse_out"
assert_contains "parse_tasks extracts TASK-002" "TASK-002" "$parse_out"
assert_contains "parse_tasks extracts TASK-003" "TASK-003" "$parse_out"

assert_contains "parse_tasks extracts title" "Add login endpoint" "$parse_out"

# Check TSV structure: each line must have 8 tab-separated fields
while IFS= read -r line; do
    field_count="$(echo "$line" | awk -F'\t' '{print NF}')"
    assert_eq "parse_tasks line has 8 TSV fields" "8" "$field_count"
done <<< "$parse_out"

task001_line="$(echo "$parse_out" | grep "^TASK-001")"
task001_blocks="$(echo "$task001_line" | cut -f6)"
assert_eq "TASK-001 blocks TASK-002" "TASK-002" "$task001_blocks"

task002_line="$(echo "$parse_out" | grep "^TASK-002")"
task002_depends="$(echo "$task002_line" | cut -f5)"
assert_eq "TASK-002 depends on TASK-001" "TASK-001" "$task002_depends"

task001_start="$(echo "$task001_line" | cut -f7)"
task001_end="$(echo "$task001_line" | cut -f8)"
if [[ "$task001_start" =~ ^[0-9]+$ ]] && [[ "$task001_end" =~ ^[0-9]+$ ]]; then
    pass "parse_tasks has integer line numbers"
else
    fail "parse_tasks line numbers not integers: start='$task001_start' end='$task001_end'"
fi

if echo "$parse_out" | grep -q "^Preamble"; then
    fail "parse_tasks emits preamble as task"
else
    pass "parse_tasks skips preamble"
fi

# extract_preamble
preamble="$(extract_preamble "$TASK_FILE")"
assert_contains "extract_preamble returns preamble content" "shared context" "$preamble"

# ---------------------------------------------------------------------------
# Section 7: extract_scoped_files from lib/task-parser.sh
# ---------------------------------------------------------------------------
echo ""
echo "=== extract_scoped_files ==="

SCOPED_TASK_FILE="$TMPDIR_TEST/scoped-tasks.md"

cat > "$SCOPED_TASK_FILE" <<'EOF'
# Preamble

Shared context.

---

### Task ID: TASK-SCOPE
**Title**: Test scoped files extraction
**Status**: `[ ]` pending
**Priority**: P1
**Depends On**: None
**Blocks**: None

**Scoped Files** (ONLY touch these):
- `src/auth/login.ts` — add OAuth handler
- `src/auth/session.ts` — update session types
- `src/tests/` — add tests

**Acceptance Criteria**:
- [ ] OAuth login works
EOF

# Find task block start (after the ---)
scoped_sep_line=$(grep -n '^---[[:space:]]*$' "$SCOPED_TASK_FILE" | head -1 | cut -d: -f1)
scoped_start=$((scoped_sep_line + 1))
scoped_total=$(wc -l < "$SCOPED_TASK_FILE" | tr -d ' ')

scoped_out="$(extract_scoped_files "$SCOPED_TASK_FILE" "$scoped_start" "$scoped_total")"
assert_contains "extract_scoped_files finds login.ts" "src/auth/login.ts" "$scoped_out"
assert_contains "extract_scoped_files finds session.ts" "src/auth/session.ts" "$scoped_out"
assert_contains "extract_scoped_files finds tests dir" "src/tests/" "$scoped_out"

scoped_count="$(echo "$scoped_out" | grep -c . || true)"
assert_eq "extract_scoped_files finds 3 entries" "3" "$scoped_count"

# Test with no scoped files section
NO_SCOPE_FILE="$TMPDIR_TEST/no-scope.md"
cat > "$NO_SCOPE_FILE" <<'EOF'
### Task ID: TASK-NOSCOPE
**Title**: No scoped files
**Priority**: P1
EOF

no_scope_out="$(extract_scoped_files "$NO_SCOPE_FILE" 1 3)"
assert_empty "extract_scoped_files returns empty when no section" "$no_scope_out"

# ---------------------------------------------------------------------------
# Section 8: validate.sh — check_scope
# ---------------------------------------------------------------------------
echo ""
echo "=== check_scope ==="

source "$PLUGIN_DIR/lib/validate.sh"

# Create a test git repo with changes
SCOPE_REPO="$TMPDIR_TEST/scope-repo"
git init --quiet "$SCOPE_REPO"
(
    cd "$SCOPE_REPO"
    git config user.email "test@test.com"
    git config user.name "Test"
    mkdir -p src/auth src/utils
    echo "original" > src/auth/login.ts
    echo "original" > src/auth/session.ts
    echo "original" > src/utils/helpers.ts
    git add -A
    git commit --quiet -m "init"
    git checkout --quiet -b wt/task-scope
    echo "modified" > src/auth/login.ts
    echo "modified" > src/utils/helpers.ts
    git add -A
    git commit --quiet -m "task changes"
) 2>/dev/null

# Test scope check — helpers.ts is out of scope
scope_result="$(check_scope "$SCOPE_REPO" "main" "src/auth/login.ts
src/auth/session.ts")"

scope_pass="$(echo "$scope_result" | jq -r '.pass')"
assert_eq "check_scope fails on out-of-scope file" "false" "$scope_pass"

scope_out_of="$(echo "$scope_result" | jq -r '.out_of_scope | length')"
assert_eq "check_scope detects 1 out-of-scope file" "1" "$scope_out_of"

scope_in="$(echo "$scope_result" | jq -r '.in_scope | length')"
assert_eq "check_scope detects 1 in-scope file" "1" "$scope_in"

# Test scope check — all files in scope (using directory glob)
scope_result_pass="$(check_scope "$SCOPE_REPO" "main" "src/auth/
src/utils/")"

scope_pass2="$(echo "$scope_result_pass" | jq -r '.pass')"
assert_eq "check_scope passes when all in scope" "true" "$scope_pass2"

# Test scope check — empty scoped files
scope_result_empty="$(check_scope "$SCOPE_REPO" "main" "")"
scope_skip="$(echo "$scope_result_empty" | jq -r '.skipped')"
assert_eq "check_scope skips when no scoped files" "no scoped files defined in task" "$scope_skip"

# ---------------------------------------------------------------------------
# Section 9: validate.sh — check_broadcast
# ---------------------------------------------------------------------------
echo ""
echo "=== check_broadcast ==="

# Create a broadcast file that matches the diff
BROADCAST_GOOD="$TMPDIR_TEST/broadcast-good.md"
cat > "$BROADCAST_GOOD" <<'EOF'
# TASK-SCOPE — Completed

## Changes Made
- Modified auth login handler
- Updated helpers

## Impact on Other Tasks
- None — fully independent

## Files Modified
- `src/auth/login.ts`
- `src/utils/helpers.ts`
EOF

bcast_result="$(check_broadcast "$SCOPE_REPO" "main" "$BROADCAST_GOOD")"
bcast_pass="$(echo "$bcast_result" | jq -r '.pass')"
assert_eq "check_broadcast passes on honest broadcast" "true" "$bcast_pass"

# Create a dishonest broadcast (missing a file, claiming a phantom)
BROADCAST_BAD="$TMPDIR_TEST/broadcast-bad.md"
cat > "$BROADCAST_BAD" <<'EOF'
# TASK-SCOPE — Completed

## Changes Made
- Modified login handler

## Files Modified
- `src/auth/login.ts`
- `src/phantom/does-not-exist.ts`
EOF

bcast_bad_result="$(check_broadcast "$SCOPE_REPO" "main" "$BROADCAST_BAD")"
bcast_bad_pass="$(echo "$bcast_bad_result" | jq -r '.pass')"
assert_eq "check_broadcast fails on dishonest broadcast" "false" "$bcast_bad_pass"

bcast_missing="$(echo "$bcast_bad_result" | jq -r '.missing_from_broadcast | length')"
assert_eq "check_broadcast detects 1 missing file" "1" "$bcast_missing"

bcast_phantom="$(echo "$bcast_bad_result" | jq -r '.phantom_in_broadcast | length')"
assert_eq "check_broadcast detects 1 phantom file" "1" "$bcast_phantom"

# Test with no broadcast file
bcast_no_file="$(check_broadcast "$SCOPE_REPO" "main" "")"
bcast_no_pass="$(echo "$bcast_no_file" | jq -r '.pass')"
assert_eq "check_broadcast fails when no broadcast file" "false" "$bcast_no_pass"

# ---------------------------------------------------------------------------
# Section 10: validate.sh — extract_broadcast_files
# ---------------------------------------------------------------------------
echo ""
echo "=== extract_broadcast_files ==="

bcast_files="$(extract_broadcast_files "$BROADCAST_GOOD")"
assert_contains "extract_broadcast_files finds login.ts" "src/auth/login.ts" "$bcast_files"
assert_contains "extract_broadcast_files finds helpers.ts" "src/utils/helpers.ts" "$bcast_files"

bfiles_count="$(echo "$bcast_files" | grep -c . || true)"
assert_eq "extract_broadcast_files finds 2 files" "2" "$bfiles_count"

# Test broadcast with bare paths (no backticks)
BROADCAST_BARE="$TMPDIR_TEST/broadcast-bare.md"
cat > "$BROADCAST_BARE" <<'EOF'
# TASK — Completed

## Files Modified
- src/file1.ts
- src/file2.ts
EOF

bare_files="$(extract_broadcast_files "$BROADCAST_BARE")"
assert_contains "extract_broadcast_files handles bare paths" "src/file1.ts" "$bare_files"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "======================================="
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "======================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
