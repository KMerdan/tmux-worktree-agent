#!/usr/bin/env bash

# Metadata management for tmux-worktree-agent
# Handles JSON storage of session data

PLUGIN_DIR="${WORKTREE_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
METADATA_FILE="$PLUGIN_DIR/.worktree-sessions.json"

# Expand tilde in path
expand_tilde() {
    local path="$1"
    echo "${path/#\~/$HOME}"
}

# Initialize metadata file if it doesn't exist
init_metadata() {
    if [ ! -f "$METADATA_FILE" ]; then
        echo '{}' > "$METADATA_FILE"
    fi
}

# Add or update session metadata
save_session() {
    local session_name="$1"
    local repo="$2"
    local topic="$3"
    local branch="$4"
    local worktree_path="$5"
    local main_repo_path="$6"
    local agent_running="${7:-false}"

    init_metadata

    local created_at
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local entry
    entry=$(jq -n \
        --arg repo "$repo" \
        --arg topic "$topic" \
        --arg branch "$branch" \
        --arg worktree_path "$worktree_path" \
        --arg main_repo_path "$main_repo_path" \
        --arg created_at "$created_at" \
        --argjson agent_running "$agent_running" \
        '{
            repo: $repo,
            topic: $topic,
            branch: $branch,
            worktree_path: $worktree_path,
            main_repo_path: $main_repo_path,
            created_at: $created_at,
            agent_running: $agent_running
        }')

    jq --arg session "$session_name" \
       --argjson entry "$entry" \
       '.[$session] = $entry' \
       "$METADATA_FILE" > "$METADATA_FILE.tmp" && mv "$METADATA_FILE.tmp" "$METADATA_FILE"
}

# Get session metadata
get_session() {
    local session_name="$1"

    if [ ! -f "$METADATA_FILE" ]; then
        echo "{}"
        return 1
    fi

    jq -r --arg session "$session_name" '.[$session] // {}' "$METADATA_FILE"
}

# Get specific field from session metadata
get_session_field() {
    local session_name="$1"
    local field="$2"

    if [ ! -f "$METADATA_FILE" ]; then
        return 1
    fi

    jq -r --arg session "$session_name" --arg field "$field" \
       '.[$session][$field] // empty' "$METADATA_FILE"
}

# Delete session metadata
delete_session() {
    local session_name="$1"

    if [ ! -f "$METADATA_FILE" ]; then
        return 0
    fi

    jq --arg session "$session_name" 'del(.[$session])' \
       "$METADATA_FILE" > "$METADATA_FILE.tmp" && mv "$METADATA_FILE.tmp" "$METADATA_FILE"
}

# List all sessions
list_sessions() {
    if [ ! -f "$METADATA_FILE" ]; then
        echo "[]"
        return 0
    fi

    jq -r 'keys[]' "$METADATA_FILE"
}

# Get all session data as array
get_all_sessions() {
    if [ ! -f "$METADATA_FILE" ]; then
        echo "[]"
        return 0
    fi

    jq -c 'to_entries | map({session: .key, data: .value})' "$METADATA_FILE"
}

# Check if session exists in metadata
session_in_metadata() {
    local session_name="$1"

    if [ ! -f "$METADATA_FILE" ]; then
        return 1
    fi

    jq -e --arg session "$session_name" '.[$session]' "$METADATA_FILE" >/dev/null 2>&1
}

# Find session by worktree path
find_session_by_path() {
    local worktree_path="$1"

    if [ ! -f "$METADATA_FILE" ]; then
        return 1
    fi

    jq -r --arg path "$worktree_path" \
       'to_entries[] | select(.value.worktree_path == $path) | .key' \
       "$METADATA_FILE"
}

# Find sessions by repo
find_sessions_by_repo() {
    local repo="$1"

    if [ ! -f "$METADATA_FILE" ]; then
        echo "[]"
        return 0
    fi

    jq -r --arg repo "$repo" \
       'to_entries[] | select(.value.repo == $repo) | .key' \
       "$METADATA_FILE"
}

# Clean orphaned metadata (sessions and worktrees both gone)
clean_orphaned_metadata() {
    if [ ! -f "$METADATA_FILE" ]; then
        return 0
    fi

    local cleaned=0
    local sessions
    sessions=$(list_sessions)

    for session in $sessions; do
        local worktree_path
        worktree_path=$(get_session_field "$session" "worktree_path")

        # Check if both session and worktree are gone
        if ! tmux has-session -t "$session" 2>/dev/null && [ ! -d "$worktree_path" ]; then
            delete_session "$session"
            ((cleaned++))
        fi
    done

    echo "$cleaned"
}

# Get orphaned sessions (session exists, worktree deleted)
get_orphaned_sessions() {
    if [ ! -f "$METADATA_FILE" ]; then
        echo "[]"
        return 0
    fi

    local orphaned=()
    local sessions
    sessions=$(list_sessions)

    for session in $sessions; do
        local worktree_path
        worktree_path=$(get_session_field "$session" "worktree_path")

        # Session exists but worktree doesn't
        if tmux has-session -t "$session" 2>/dev/null && [ ! -d "$worktree_path" ]; then
            orphaned+=("$session")
        fi
    done

    printf '%s\n' "${orphaned[@]}"
}

# Get orphaned worktrees (worktree exists, no session)
get_orphaned_worktrees() {
    local repo_path="$1"
    local worktree_base
    worktree_base=$(expand_tilde "${WORKTREE_PATH:-$HOME/.worktrees}")

    if [ ! -d "$worktree_base" ]; then
        echo "[]"
        return 0
    fi

    local orphaned=()
    local repo_name
    repo_name=$(basename "$repo_path")

    # Get all worktrees for this repo from git
    if [ -d "$repo_path" ]; then
        cd "$repo_path" || return 1

        local worktrees
        worktrees=$(git worktree list --porcelain | awk '/^worktree / {print $2}')

        for wt_path in $worktrees; do
            # Skip main worktree
            if [ "$wt_path" = "$repo_path" ]; then
                continue
            fi

            # Check if in our managed location
            if [[ "$wt_path" == "$worktree_base"* ]]; then
                # Check if we have a session for this worktree
                local session
                session=$(find_session_by_path "$wt_path")

                if [ -z "$session" ] || ! tmux has-session -t "$session" 2>/dev/null; then
                    orphaned+=("$wt_path")
                fi
            fi
        done
    fi

    printf '%s\n' "${orphaned[@]}"
}

# Count sessions
count_sessions() {
    if [ ! -f "$METADATA_FILE" ]; then
        echo "0"
        return 0
    fi

    jq 'length' "$METADATA_FILE"
}

# Export all metadata as formatted text
export_metadata() {
    if [ ! -f "$METADATA_FILE" ]; then
        echo "No sessions"
        return 0
    fi

    jq -r 'to_entries[] |
        "\(.key)\n  Repo: \(.value.repo)\n  Branch: \(.value.branch)\n  Path: \(.value.worktree_path)\n  Created: \(.value.created_at)\n"' \
        "$METADATA_FILE"
}

# Backup metadata
backup_metadata() {
    if [ -f "$METADATA_FILE" ]; then
        local backup_file="$METADATA_FILE.backup-$(date +%Y%m%d-%H%M%S)"
        cp "$METADATA_FILE" "$backup_file"
        echo "$backup_file"
    fi
}

# Restore metadata from backup
restore_metadata() {
    local backup_file="$1"

    if [ -f "$backup_file" ]; then
        cp "$backup_file" "$METADATA_FILE"
        return 0
    else
        return 1
    fi
}
