#!/usr/bin/env bash

# Validation engine for tmux-worktree-agent
# Deterministic checks that replace "trust the agent" with automated verification.
#
# Each check function outputs a JSON object to stdout.
# Diagnostic/error messages go to stderr.
# Source this file — no side effects on import.

PLUGIN_DIR="${WORKTREE_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Source dependencies (guard against double-source)
if ! type get_session_field &>/dev/null; then
    source "$PLUGIN_DIR/lib/metadata.sh"
fi
if ! type parse_tasks &>/dev/null; then
    source "$PLUGIN_DIR/lib/task-parser.sh"
fi
if ! type get_default_branch &>/dev/null; then
    source "$PLUGIN_DIR/scripts/utils.sh"
fi

# ── Config ─────────────────────────────────────────────────────────────

# Defaults — overridden by .wta/validate.conf
WTA_BUILD_CMD=""
WTA_TEST_CMD=""
WTA_CHECK_TIMEOUT=120
WTA_CHECKS="scope,broadcast"
WTA_STOP_ON_FAIL=false
WTA_STRICT_TOOLS=false
WTA_SCOPE_STRICTNESS="fail"
WTA_AST_RULES_DIR=""
WTA_GRAPH_TOOL=""
WTA_GRAPH_CMD=""

# Load per-project validation config
# Searches: worktree/.wta/validate.conf → main_repo/.wta/validate.conf → defaults
load_validate_config() {
    local worktree_path="${1:-}"
    local main_repo_path="${2:-}"

    # Reset to defaults
    WTA_BUILD_CMD=""
    WTA_TEST_CMD=""
    WTA_CHECK_TIMEOUT=120
    WTA_CHECKS="scope,broadcast"
    WTA_STOP_ON_FAIL=false
    WTA_STRICT_TOOLS=false
    WTA_SCOPE_STRICTNESS="fail"
    WTA_AST_RULES_DIR=""
    WTA_GRAPH_TOOL=""
    WTA_GRAPH_CMD=""

    local conf=""
    if [ -n "$worktree_path" ] && [ -f "$worktree_path/.wta/validate.conf" ]; then
        conf="$worktree_path/.wta/validate.conf"
    elif [ -n "$main_repo_path" ] && [ -f "$main_repo_path/.wta/validate.conf" ]; then
        conf="$main_repo_path/.wta/validate.conf"
    fi

    if [ -n "$conf" ]; then
        # Source the config (it's key=value bash)
        # shellcheck disable=SC1090
        source "$conf"
    fi
}

# ── Helpers ────────────────────────────────────────────────────────────

# Cross-platform timeout command
_timeout_cmd() {
    if command -v gtimeout &>/dev/null; then
        echo "gtimeout"
    elif command -v timeout &>/dev/null; then
        echo "timeout"
    else
        echo ""
    fi
}

# Build a JSON string array from newline-separated input
_json_array() {
    local input="$1"
    if [ -z "$input" ]; then
        echo "[]"
        return
    fi
    echo "$input" | jq -R '.' | jq -s '.'
}

# Check if a file path matches any pattern in a list
# Patterns can be exact paths or directory prefixes (ending with /)
_path_matches_scope() {
    local filepath="$1"
    local scoped_files="$2"

    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        # Directory prefix match: pattern "src/auth/" matches "src/auth/login.ts"
        if [[ "$pattern" == */ ]] && [[ "$filepath" == "$pattern"* ]]; then
            return 0
        fi
        # Exact match
        if [ "$filepath" = "$pattern" ]; then
            return 0
        fi
        # Glob match (pattern without trailing slash, filepath starts with pattern path)
        local pattern_dir
        pattern_dir=$(dirname "$pattern")
        if [ "$pattern_dir" != "." ] && [[ "$filepath" == "$pattern_dir/"* ]]; then
            # Only match if the pattern looks like a directory reference
            # e.g., pattern "src/tests/*.ts" shouldn't match "src/tests/subfolder/other.py"
            # but we keep it simple: if pattern has a wildcard, use bash globbing
            if [[ "$pattern" == *"*"* ]]; then
                # shellcheck disable=SC2254
                case "$filepath" in
                    $pattern) return 0 ;;
                esac
            fi
        fi
    done <<< "$scoped_files"

    return 1
}

# Filter out plugin scaffolding files from a file list.
# A file is filtered only if it matches a scaffolding pattern AND is not
# tracked in parent_branch — tracked files are real project files whose
# modifications must always be seen by validation, even if their names
# collide with scaffolding patterns (e.g. a project's own CLAUDE.md).
_filter_scaffolding() {
    local input="$1"
    local worktree_path="$2"
    local parent_branch="$3"

    [ -z "$input" ] && return 0

    local tracked
    tracked=$(git -C "$worktree_path" ls-tree -r "$parent_branch" --name-only 2>/dev/null)

    local pattern='^\.shared$|^\.shared/|^wt-.*\.md$|^CLAUDE\.md$|^AGENTS\.md$|^GEMINI\.md$|^\.wta/'

    while IFS= read -r file; do
        [ -z "$file" ] && continue
        if echo "$file" | grep -qE "$pattern"; then
            # Matches scaffolding pattern — keep it only if tracked in parent
            if echo "$tracked" | grep -qFx "$file"; then
                echo "$file"
            fi
            # else: drop (unrecognized scaffolding)
        else
            echo "$file"
        fi
    done <<< "$input"
}

# ── Check: Scope Enforcement ──────────────────────────────────────────

# Compare git diff --name-only against scoped file list
# Args: worktree_path, parent_branch, scoped_files (newline-separated)
# Output: JSON { check, pass, in_scope, out_of_scope, untouched_scope }
check_scope() {
    local worktree_path="$1"
    local parent_branch="$2"
    local scoped_files="$3"

    if [ -z "$scoped_files" ]; then
        jq -n '{
            check: "scope",
            pass: true,
            skipped: "no scoped files defined in task",
            in_scope: [],
            out_of_scope: [],
            untouched_scope: []
        }'
        return 0
    fi

    # Get actual changed files, excluding plugin scaffolding
    local changed_files_raw changed_files
    changed_files_raw=$(cd "$worktree_path" && git diff --name-only "${parent_branch}...HEAD" 2>/dev/null)
    changed_files=$(_filter_scaffolding "$changed_files_raw" "$worktree_path" "$parent_branch")

    if [ -z "$changed_files" ]; then
        jq -n --argjson scoped "$(_json_array "$scoped_files")" '{
            check: "scope",
            pass: true,
            skipped: null,
            in_scope: [],
            out_of_scope: [],
            untouched_scope: $scoped
        }'
        return 0
    fi

    local in_scope=""
    local out_of_scope=""

    while IFS= read -r filepath; do
        [ -z "$filepath" ] && continue
        if _path_matches_scope "$filepath" "$scoped_files"; then
            in_scope+="${filepath}"$'\n'
        else
            out_of_scope+="${filepath}"$'\n'
        fi
    done <<< "$changed_files"

    # Remove trailing newlines
    in_scope="${in_scope%$'\n'}"
    out_of_scope="${out_of_scope%$'\n'}"

    # Find untouched scoped files (scoped but not in changed_files)
    local untouched=""
    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue
        local touched=false
        while IFS= read -r filepath; do
            [ -z "$filepath" ] && continue
            if _path_matches_scope "$filepath" "$pattern"; then
                touched=true
                break
            fi
        done <<< "$changed_files"
        if [ "$touched" = false ]; then
            untouched+="${pattern}"$'\n'
        fi
    done <<< "$scoped_files"
    untouched="${untouched%$'\n'}"

    local pass=true
    if [ -n "$out_of_scope" ] && [ "$WTA_SCOPE_STRICTNESS" = "fail" ]; then
        pass=false
    fi

    jq -n \
        --argjson pass "$pass" \
        --argjson in_scope "$(_json_array "$in_scope")" \
        --argjson out_of_scope "$(_json_array "$out_of_scope")" \
        --argjson untouched "$(_json_array "$untouched")" \
        '{
            check: "scope",
            pass: $pass,
            skipped: null,
            in_scope: $in_scope,
            out_of_scope: $out_of_scope,
            untouched_scope: $untouched
        }'
}

# ── Check: Broadcast Verification ─────────────────────────────────────

# Extract file paths from broadcast's "## Files Modified" section
extract_broadcast_files() {
    local broadcast_file="$1"

    [ -f "$broadcast_file" ] || return 0

    awk '
        /^## Files Modified/ { capture=1; next }
        /^## / { if (capture) exit }
        capture && /`[^`]+`/ {
            line = $0
            match(line, /`[^`]+`/)
            if (RSTART > 0) {
                path = substr(line, RSTART+1, RLENGTH-2)
                print path
            }
        }
        capture && /^- / && !/`/ {
            # Handle bare paths without backticks: "- src/file.ts"
            line = $0
            sub(/^- */, "", line)
            sub(/ .*/, "", line)  # strip trailing description
            if (length(line) > 0) print line
        }
    ' "$broadcast_file"
}

# Compare broadcast claims vs actual git diff
# Args: worktree_path, parent_branch, broadcast_file
# Output: JSON { check, pass, claimed, actual, missing_from_broadcast, phantom_in_broadcast }
check_broadcast() {
    local worktree_path="$1"
    local parent_branch="$2"
    local broadcast_file="$3"

    if [ -z "$broadcast_file" ] || [ ! -f "$broadcast_file" ]; then
        jq -n '{
            check: "broadcast",
            pass: false,
            skipped: "no broadcast file found",
            claimed: [],
            actual: [],
            missing_from_broadcast: [],
            phantom_in_broadcast: []
        }'
        return 0
    fi

    local claimed_files
    claimed_files=$(extract_broadcast_files "$broadcast_file")

    # Get actual changed files, excluding plugin scaffolding
    local actual_files_raw actual_files
    actual_files_raw=$(cd "$worktree_path" && git diff --name-only "${parent_branch}...HEAD" 2>/dev/null)
    actual_files=$(_filter_scaffolding "$actual_files_raw" "$worktree_path" "$parent_branch")

    # Find files in actual but not in claimed (agent forgot to report)
    local missing=""
    while IFS= read -r filepath; do
        [ -z "$filepath" ] && continue
        if ! echo "$claimed_files" | grep -qFx "$filepath"; then
            missing+="${filepath}"$'\n'
        fi
    done <<< "$actual_files"
    missing="${missing%$'\n'}"

    # Find files in claimed but not in actual (agent lied or file was reverted)
    local phantom=""
    while IFS= read -r filepath; do
        [ -z "$filepath" ] && continue
        if ! echo "$actual_files" | grep -qFx "$filepath"; then
            phantom+="${filepath}"$'\n'
        fi
    done <<< "$claimed_files"
    phantom="${phantom%$'\n'}"

    local pass=true
    if [ -n "$missing" ] || [ -n "$phantom" ]; then
        pass=false
    fi

    jq -n \
        --argjson pass "$pass" \
        --argjson claimed "$(_json_array "$claimed_files")" \
        --argjson actual "$(_json_array "$actual_files")" \
        --argjson missing "$(_json_array "$missing")" \
        --argjson phantom "$(_json_array "$phantom")" \
        '{
            check: "broadcast",
            pass: $pass,
            skipped: null,
            claimed: $claimed,
            actual: $actual,
            missing_from_broadcast: $missing,
            phantom_in_broadcast: $phantom
        }'
}

# ── Check: Build ──────────────────────────────────────────────────────

check_build() {
    local worktree_path="$1"

    if [ -z "$WTA_BUILD_CMD" ]; then
        jq -n '{
            check: "build",
            pass: true,
            skipped: "no build command configured",
            command: null,
            exit_code: null,
            output_tail: null
        }'
        return 0
    fi

    local timeout_cmd
    timeout_cmd=$(_timeout_cmd)

    local output_file exit_code
    output_file=$(mktemp)

    if [ -n "$timeout_cmd" ]; then
        (cd "$worktree_path" && $timeout_cmd "$WTA_CHECK_TIMEOUT" bash -c "$WTA_BUILD_CMD" >"$output_file" 2>&1) && exit_code=0 || exit_code=$?
    else
        (cd "$worktree_path" && bash -c "$WTA_BUILD_CMD" >"$output_file" 2>&1) && exit_code=0 || exit_code=$?
    fi

    local pass=true
    [ "$exit_code" -ne 0 ] && pass=false

    local tail_output
    tail_output=$(tail -80 "$output_file")
    rm -f "$output_file"

    jq -n \
        --argjson pass "$pass" \
        --arg command "$WTA_BUILD_CMD" \
        --argjson exit_code "$exit_code" \
        --arg output_tail "$tail_output" \
        '{
            check: "build",
            pass: $pass,
            skipped: null,
            command: $command,
            exit_code: $exit_code,
            output_tail: $output_tail
        }'
}

# ── Check: Test ───────────────────────────────────────────────────────

check_test() {
    local worktree_path="$1"

    if [ -z "$WTA_TEST_CMD" ]; then
        jq -n '{
            check: "test",
            pass: true,
            skipped: "no test command configured",
            command: null,
            exit_code: null,
            output_tail: null
        }'
        return 0
    fi

    local timeout_cmd
    timeout_cmd=$(_timeout_cmd)

    local output_file exit_code
    output_file=$(mktemp)

    if [ -n "$timeout_cmd" ]; then
        (cd "$worktree_path" && $timeout_cmd "$WTA_CHECK_TIMEOUT" bash -c "$WTA_TEST_CMD" >"$output_file" 2>&1) && exit_code=0 || exit_code=$?
    else
        (cd "$worktree_path" && bash -c "$WTA_TEST_CMD" >"$output_file" 2>&1) && exit_code=0 || exit_code=$?
    fi

    local pass=true
    [ "$exit_code" -ne 0 ] && pass=false

    local tail_output
    tail_output=$(tail -80 "$output_file")
    rm -f "$output_file"

    jq -n \
        --argjson pass "$pass" \
        --arg command "$WTA_TEST_CMD" \
        --argjson exit_code "$exit_code" \
        --arg output_tail "$tail_output" \
        '{
            check: "test",
            pass: $pass,
            skipped: null,
            command: $command,
            exit_code: $exit_code,
            output_tail: $output_tail
        }'
}

# ── Check: AST (ast-grep) ────────────────────────────────────────────

check_ast() {
    local worktree_path="$1"
    local parent_branch="$2"

    if ! command -v ast-grep &>/dev/null; then
        local pass=true
        [ "$WTA_STRICT_TOOLS" = true ] && pass=false
        jq -n --argjson pass "$pass" '{
            check: "ast",
            pass: $pass,
            skipped: "ast-grep not installed",
            findings: []
        }'
        return 0
    fi

    # Get modified files
    local changed_files
    changed_files=$(cd "$worktree_path" && git diff --name-only "${parent_branch}...HEAD" 2>/dev/null)

    if [ -z "$changed_files" ]; then
        jq -n '{
            check: "ast",
            pass: true,
            skipped: "no files changed",
            findings: []
        }'
        return 0
    fi

    # Determine rules source
    local scan_args=""
    if [ -n "$WTA_AST_RULES_DIR" ] && [ -d "$worktree_path/$WTA_AST_RULES_DIR" ]; then
        scan_args="--rule $worktree_path/$WTA_AST_RULES_DIR"
    elif [ -f "$worktree_path/sgconfig.yml" ] || [ -f "$worktree_path/.ast-grep.yml" ]; then
        scan_args=""  # ast-grep auto-detects config
    else
        # No rules configured — skip
        jq -n '{
            check: "ast",
            pass: true,
            skipped: "no ast-grep rules configured",
            findings: []
        }'
        return 0
    fi

    # Run ast-grep scan on changed files, output as JSON
    local output
    output=$(cd "$worktree_path" && echo "$changed_files" | xargs ast-grep scan $scan_args --json 2>/dev/null) || true

    if [ -z "$output" ] || [ "$output" = "[]" ] || [ "$output" = "null" ]; then
        jq -n '{
            check: "ast",
            pass: true,
            skipped: null,
            findings: []
        }'
        return 0
    fi

    # Parse ast-grep JSON output into our format
    local findings
    findings=$(echo "$output" | jq '[.[] | {
        rule: (.ruleId // .rule_id // "unknown"),
        file: (.file // .path // "unknown"),
        line: (.range.start.line // .start.line // 0),
        message: (.message // .note // "")
    }]' 2>/dev/null) || findings="[]"

    local finding_count
    finding_count=$(echo "$findings" | jq 'length')

    local pass=true
    [ "$finding_count" -gt 0 ] && pass=false

    jq -n \
        --argjson pass "$pass" \
        --argjson findings "$findings" \
        '{
            check: "ast",
            pass: $pass,
            skipped: null,
            findings: $findings
        }'
}

# ── Check: Code Graph ─────────────────────────────────────────────────

check_graph() {
    local worktree_path="$1"
    local parent_branch="$2"

    # Source graph library if available
    local graph_lib="$PLUGIN_DIR/lib/graph.sh"
    if [ -f "$graph_lib" ]; then
        # shellcheck disable=SC1090
        source "$graph_lib"
    fi

    # Determine tool
    local tool="$WTA_GRAPH_TOOL"
    if [ -z "$tool" ]; then
        # Auto-detect
        if [ -f "$worktree_path/package.json" ] && command -v madge &>/dev/null; then
            tool="madge"
        elif [ -f "$worktree_path/pyproject.toml" ] && command -v pydeps &>/dev/null; then
            tool="pydeps"
        fi
    fi

    if [ -z "$tool" ]; then
        local pass=true
        [ "$WTA_STRICT_TOOLS" = true ] && pass=false
        jq -n --argjson pass "$pass" '{
            check: "graph",
            pass: $pass,
            skipped: "no graph tool available",
            circular: []
        }'
        return 0
    fi

    local circular=""
    local exit_code=0

    case "$tool" in
        madge)
            local output
            output=$(cd "$worktree_path" && madge --circular --json . 2>/dev/null) || exit_code=$?
            if [ -n "$output" ] && [ "$output" != "[]" ]; then
                circular="$output"
            fi
            ;;
        pydeps)
            # pydeps doesn't have a direct circular check, use custom approach
            local output
            output=$(cd "$worktree_path" && python3 -c "
import sys, json, ast, os
# Simple circular import detector for changed Python files
changed = sys.stdin.read().strip().split('\n')
imports = {}
for f in changed:
    if not f.endswith('.py') or not os.path.exists(f):
        continue
    try:
        tree = ast.parse(open(f).read())
        mods = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    mods.add(alias.name)
            elif isinstance(node, ast.ImportFrom) and node.module:
                mods.add(node.module)
        imports[f] = list(mods)
    except:
        pass
# Detect simple cycles
cycles = []
for a, a_imports in imports.items():
    for b, b_imports in imports.items():
        if a != b:
            a_mod = a.replace('/', '.').replace('.py', '')
            b_mod = b.replace('/', '.').replace('.py', '')
            if any(b_mod in i for i in a_imports) and any(a_mod in i for i in b_imports):
                cycle = sorted([a, b])
                if cycle not in cycles:
                    cycles.append(cycle)
print(json.dumps(cycles))
" <<< "$(cd "$worktree_path" && git diff --name-only "${parent_branch}...HEAD" 2>/dev/null)" 2>/dev/null) || exit_code=$?
            if [ -n "$output" ] && [ "$output" != "[]" ]; then
                circular="$output"
            fi
            ;;
        custom)
            if [ -n "$WTA_GRAPH_CMD" ]; then
                local output
                output=$(cd "$worktree_path" && bash -c "$WTA_GRAPH_CMD" 2>/dev/null) || exit_code=$?
                if [ -n "$output" ]; then
                    circular="$output"
                fi
            fi
            ;;
    esac

    [ -z "$circular" ] && circular="[]"

    local circ_count
    circ_count=$(echo "$circular" | jq 'length' 2>/dev/null) || circ_count=0

    local pass=true
    [ "$circ_count" -gt 0 ] && pass=false

    jq -n \
        --argjson pass "$pass" \
        --arg tool "$tool" \
        --argjson circular "$circular" \
        '{
            check: "graph",
            pass: $pass,
            skipped: null,
            tool: $tool,
            circular: $circular
        }'
}

# ── Pipeline Runner ───────────────────────────────────────────────────

# Locate the task file (wt-*.md) in a worktree
_find_task_file() {
    local worktree_path="$1"
    for f in "$worktree_path"/wt-*.md; do
        [ -f "$f" ] && echo "$f" && return 0
    done
    return 1
}

# Locate broadcast file for a session
_find_broadcast_file() {
    local worktree_path="$1"
    local topic="$2"

    local shared_dir
    shared_dir="$(dirname "$worktree_path")/.shared"

    # Try exact topic match first, then case-insensitive
    for f in "$shared_dir/broadcasts"/*.md; do
        [ -f "$f" ] || continue
        local bid
        bid=$(basename "$f" .md)
        local sanitized_bid
        sanitized_bid=$(echo "$bid" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        local sanitized_topic
        sanitized_topic=$(echo "$topic" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        if [ "$sanitized_bid" = "$sanitized_topic" ]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# Find scoped files for a session by locating its task block
_resolve_scoped_files() {
    local worktree_path="$1"
    local task_file
    task_file=$(_find_task_file "$worktree_path") || return 0

    # The task file contains preamble + --- + task block
    # Find the task block's start line (after the ---)
    local separator_line
    separator_line=$(grep -n '^---[[:space:]]*$' "$task_file" | head -1 | cut -d: -f1)

    if [ -z "$separator_line" ]; then
        # No separator — entire file is the task
        local total_lines
        total_lines=$(wc -l < "$task_file" | tr -d ' ')
        extract_scoped_files "$task_file" 1 "$total_lines"
    else
        local start=$((separator_line + 1))
        local total_lines
        total_lines=$(wc -l < "$task_file" | tr -d ' ')
        extract_scoped_files "$task_file" "$start" "$total_lines"
    fi
}

# Run the full validation pipeline for a session
# Args: session_name [single_check]
# Output: JSON { session, branch, worktree, timestamp, all_pass, checks: [...] }
run_validation_pipeline() {
    local session_name="$1"
    local single_check="${2:-}"

    # Resolve session metadata
    if ! session_in_metadata "$session_name"; then
        echo "Session '$session_name' not found in metadata." >&2
        return 1
    fi

    local worktree_path parent_branch main_repo_path branch topic
    worktree_path=$(get_session_field "$session_name" "worktree_path")
    parent_branch=$(get_session_field "$session_name" "parent_branch")
    main_repo_path=$(get_session_field "$session_name" "main_repo_path")
    branch=$(get_session_field "$session_name" "branch")
    topic=$(get_session_field "$session_name" "topic")

    if [ -z "$parent_branch" ]; then
        parent_branch=$(get_default_branch "$main_repo_path")
    fi

    if [ ! -d "$worktree_path" ]; then
        echo "Worktree not found: $worktree_path" >&2
        return 1
    fi

    # Load config
    load_validate_config "$worktree_path" "$main_repo_path"

    # Resolve check inputs
    local scoped_files
    scoped_files=$(_resolve_scoped_files "$worktree_path")

    local broadcast_file
    broadcast_file=$(_find_broadcast_file "$worktree_path" "$topic") || broadcast_file=""

    # Determine which checks to run
    local checks_to_run="$WTA_CHECKS"
    if [ -n "$single_check" ]; then
        checks_to_run="$single_check"
    fi

    # Run checks, accumulate JSON results
    local results="[]"
    local all_pass=true
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    IFS=',' read -ra check_list <<< "$checks_to_run"
    for check_name in "${check_list[@]}"; do
        check_name=$(echo "$check_name" | tr -d ' ')
        local result=""

        case "$check_name" in
            scope)
                result=$(check_scope "$worktree_path" "$parent_branch" "$scoped_files")
                ;;
            broadcast)
                result=$(check_broadcast "$worktree_path" "$parent_branch" "$broadcast_file")
                ;;
            build)
                result=$(check_build "$worktree_path")
                ;;
            test)
                result=$(check_test "$worktree_path")
                ;;
            ast)
                result=$(check_ast "$worktree_path" "$parent_branch")
                ;;
            graph)
                result=$(check_graph "$worktree_path" "$parent_branch")
                ;;
            *)
                echo "Unknown check: $check_name" >&2
                continue
                ;;
        esac

        if [ -n "$result" ]; then
            results=$(echo "$results" | jq --argjson r "$result" '. + [$r]')

            local check_pass
            check_pass=$(echo "$result" | jq -r '.pass')
            if [ "$check_pass" = "false" ]; then
                all_pass=false
                if [ "$WTA_STOP_ON_FAIL" = true ]; then
                    break
                fi
            fi
        fi
    done

    # Assemble final report
    jq -n \
        --arg session "$session_name" \
        --arg branch "$branch" \
        --arg worktree "$worktree_path" \
        --arg timestamp "$timestamp" \
        --argjson all_pass "$all_pass" \
        --argjson checks "$results" \
        '{
            session: $session,
            branch: $branch,
            worktree: $worktree,
            timestamp: $timestamp,
            all_pass: $all_pass,
            checks: $checks
        }'
}
