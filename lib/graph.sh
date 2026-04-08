#!/usr/bin/env bash

# Code graph analysis for tmux-worktree-agent
# Import chain validation and circular dependency detection.
# Source this file — no side effects on import.

# Detect which graph tool is available for a project
# Args: worktree_path
# Output: "madge" | "pydeps" | "" (empty if none)
detect_graph_tool() {
    local worktree_path="$1"

    if [ -f "$worktree_path/package.json" ] && command -v madge &>/dev/null; then
        echo "madge"
        return 0
    fi

    if [ -f "$worktree_path/pyproject.toml" ] || [ -f "$worktree_path/setup.py" ]; then
        if command -v python3 &>/dev/null; then
            echo "pydeps"
            return 0
        fi
    fi

    return 1
}

# Find circular dependencies using madge (JS/TS projects)
# Args: worktree_path
# Output: JSON array of circular dependency chains
find_circular_madge() {
    local worktree_path="$1"

    local output
    output=$(cd "$worktree_path" && madge --circular --json . 2>/dev/null) || true

    if [ -z "$output" ] || [ "$output" = "[]" ]; then
        echo "[]"
        return 0
    fi

    echo "$output"
}

# Find circular dependencies in Python files using AST analysis
# Args: worktree_path, changed_files (newline-separated)
# Output: JSON array of circular dependency pairs
find_circular_python() {
    local worktree_path="$1"
    local changed_files="$2"

    [ -z "$changed_files" ] && { echo "[]"; return 0; }

    cd "$worktree_path" && python3 -c "
import sys, json, ast, os

changed = [f.strip() for f in sys.stdin.read().strip().split('\n') if f.strip()]
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
    except Exception:
        pass

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
" <<< "$changed_files" 2>/dev/null || echo "[]"
}

# Check import chain integrity for changed files
# Compares the import graph of changed files against the parent branch
# Args: worktree_path, parent_branch
# Output: JSON { broken_imports: [...], new_circular: [...] }
check_import_chain() {
    local worktree_path="$1"
    local parent_branch="$2"

    local changed_files
    changed_files=$(cd "$worktree_path" && git diff --name-only "${parent_branch}...HEAD" 2>/dev/null)
    [ -z "$changed_files" ] && { echo '{"broken_imports":[],"new_circular":[]}'; return 0; }

    local tool
    tool=$(detect_graph_tool "$worktree_path") || tool=""

    local circular="[]"
    case "$tool" in
        madge)
            circular=$(find_circular_madge "$worktree_path")
            ;;
        pydeps)
            circular=$(find_circular_python "$worktree_path" "$changed_files")
            ;;
    esac

    jq -n \
        --argjson circular "$circular" \
        '{
            broken_imports: [],
            new_circular: $circular
        }'
}
