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

# Initialize metadata file if it doesn't exist.
# Also quarantines corrupted metadata (invalid JSON) by renaming it with a
# timestamp suffix and starting fresh — the bad file is preserved for manual
# recovery, not deleted.
init_metadata() {
    if [ ! -f "$METADATA_FILE" ]; then
        echo '{}' > "$METADATA_FILE"
        return
    fi
    if ! jq -e . "$METADATA_FILE" >/dev/null 2>&1; then
        mv "$METADATA_FILE" "${METADATA_FILE}.corrupted.$(date +%s)"
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
    local description="${8:-}"
    local agent_cmd="${9:-}"
    local parent_branch="${10:-}"
    local parent_session="${11:-}"

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
        --arg description "$description" \
        --arg agent_cmd "$agent_cmd" \
        --arg parent_branch "$parent_branch" \
        --arg parent_session "$parent_session" \
        '{
            repo: $repo,
            topic: $topic,
            branch: $branch,
            worktree_path: $worktree_path,
            main_repo_path: $main_repo_path,
            created_at: $created_at,
            agent_running: $agent_running,
            description: $description,
            agent_cmd: $agent_cmd,
            parent_branch: $parent_branch,
            parent_session: $parent_session
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
        return 0
    fi

    jq -r 'keys[]' "$METADATA_FILE"
}

# Get all session data as array
get_all_sessions() {
    if [ ! -f "$METADATA_FILE" ]; then
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
            cleaned=$((cleaned + 1))
        fi
    done

    echo "$cleaned"
}

# Count sessions
count_sessions() {
    if [ ! -f "$METADATA_FILE" ]; then
        echo "0"
        return 0
    fi

    jq 'length' "$METADATA_FILE"
}

# Update session description
update_session_description() {
    local session_name="$1"
    local description="$2"

    if [ ! -f "$METADATA_FILE" ]; then
        return 1
    fi

    if ! session_in_metadata "$session_name"; then
        return 1
    fi

    jq --arg session "$session_name" \
       --arg description "$description" \
       '.[$session].description = $description' \
       "$METADATA_FILE" > "$METADATA_FILE.tmp" && mv "$METADATA_FILE.tmp" "$METADATA_FILE"
}

# Get session description
get_session_description() {
    local session_name="$1"

    if [ ! -f "$METADATA_FILE" ]; then
        return 1
    fi

    jq -r --arg session "$session_name" \
       '.[$session].description // empty' \
       "$METADATA_FILE"
}

# Set sidebar_task_file on a session (marks it as a sidebar host)
set_sidebar_task_file() {
    local session_name="$1"
    local task_file="$2"

    if [ ! -f "$METADATA_FILE" ]; then
        return 1
    fi

    if ! session_in_metadata "$session_name"; then
        return 1
    fi

    jq --arg session "$session_name" \
       --arg tf "$task_file" \
       '.[$session].sidebar_task_file = $tf' \
       "$METADATA_FILE" > "$METADATA_FILE.tmp" && mv "$METADATA_FILE.tmp" "$METADATA_FILE"
}

# Clear sidebar_task_file from a session
clear_sidebar_task_file() {
    local session_name="$1"

    if [ ! -f "$METADATA_FILE" ]; then
        return 1
    fi

    if ! session_in_metadata "$session_name"; then
        return 1
    fi

    jq --arg session "$session_name" \
       'del(.[$session].sidebar_task_file)' \
       "$METADATA_FILE" > "$METADATA_FILE.tmp" && mv "$METADATA_FILE.tmp" "$METADATA_FILE"
}

# Find the sidebar host session for a given repo name
# Returns the session name that has sidebar_task_file set for that repo
find_sidebar_session_for_repo() {
    local repo="$1"

    if [ ! -f "$METADATA_FILE" ]; then
        return 1
    fi

    jq -r --arg repo "$repo" \
       'to_entries[] | select(.value.repo == $repo and .value.sidebar_task_file != null) | .key' \
       "$METADATA_FILE" | head -1
}

# Set sidebar_test_task_file on a session (marks it as a test sidebar host)
set_sidebar_test_task_file() {
    local session_name="$1"
    local task_file="$2"

    if [ ! -f "$METADATA_FILE" ]; then
        return 1
    fi

    if ! session_in_metadata "$session_name"; then
        return 1
    fi

    jq --arg session "$session_name" \
       --arg tf "$task_file" \
       '.[$session].sidebar_test_task_file = $tf' \
       "$METADATA_FILE" > "$METADATA_FILE.tmp" && mv "$METADATA_FILE.tmp" "$METADATA_FILE"
}

# Clear sidebar_test_task_file from a session
clear_sidebar_test_task_file() {
    local session_name="$1"

    if [ ! -f "$METADATA_FILE" ]; then
        return 1
    fi

    if ! session_in_metadata "$session_name"; then
        return 1
    fi

    jq --arg session "$session_name" \
       'del(.[$session].sidebar_test_task_file)' \
       "$METADATA_FILE" > "$METADATA_FILE.tmp" && mv "$METADATA_FILE.tmp" "$METADATA_FILE"
}

# Find the test sidebar host session for a given repo name
# Returns the session name that has sidebar_test_task_file set for that repo
find_sidebar_test_session_for_repo() {
    local repo="$1"

    if [ ! -f "$METADATA_FILE" ]; then
        return 1
    fi

    jq -r --arg repo "$repo" \
       'to_entries[] | select(.value.repo == $repo and .value.sidebar_test_task_file != null) | .key' \
       "$METADATA_FILE" | head -1
}

# Get session agent command
get_session_agent() {
    local session_name="$1"

    if [ ! -f "$METADATA_FILE" ]; then
        return 1
    fi

    jq -r --arg session "$session_name" \
       '.[$session].agent_cmd // empty' \
       "$METADATA_FILE"
}

