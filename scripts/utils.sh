#!/usr/bin/env bash

# Shared utilities for tmux-worktree-agent

# Get plugin directory
PLUGIN_DIR="${WORKTREE_PLUGIN_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
METADATA_FILE="$PLUGIN_DIR/.worktree-sessions.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ${NC} $*"
}

log_success() {
    echo -e "${GREEN}✓${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $*"
}

log_error() {
    echo -e "${RED}✗${NC} $*"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check required dependencies
check_dependencies() {
    local missing=()

    if ! command_exists git; then
        missing+=("git")
    fi

    if ! command_exists jq; then
        missing+=("jq")
    fi

    if ! command_exists fzf; then
        missing+=("fzf")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_info "Please install: ${missing[*]}"
        return 1
    fi

    return 0
}

# Get git repository name
get_repo_name() {
    local repo_path="$1"

    # Try to get from remote URL
    local remote_url
    remote_url=$(cd "$repo_path" && git remote get-url origin 2>/dev/null)

    if [ -n "$remote_url" ]; then
        # Extract repo name from URL
        basename "$remote_url" .git
    else
        # Use directory name
        basename "$repo_path"
    fi
}

# Check if in git repository
is_git_repo() {
    git rev-parse --show-toplevel >/dev/null 2>&1
}

# Get git repository root
get_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

# Get current branch
get_current_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null
}

# Sanitize name for use in paths and session names
sanitize_name() {
    echo "$1" | tr '/' '-' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
}

# Generate session name
generate_session_name() {
    local repo="$1"
    local topic="$2"
    echo "${repo}-${topic}"
}

# Check if tmux session exists
session_exists() {
    tmux has-session -t "$1" 2>/dev/null
}

# Prompt user (with fallback from gum to read)
prompt() {
    local message="$1"
    local default="${2:-}"

    if command_exists gum; then
        gum input --placeholder "$message" --value "$default"
    else
        echo -n "$message"
        if [ -n "$default" ]; then
            echo -n " [$default]"
        fi
        echo -n ": "
        read -r response
        echo "${response:-$default}"
    fi
}

# Confirm action
confirm() {
    local message="$1"
    local default="${2:-n}"

    if command_exists gum; then
        gum confirm "$message"
        return $?
    else
        echo -n "$message [y/N]: "
        read -r response
        case "$response" in
            [yY]|[yY][eE][sS]) return 0 ;;
            *) return 1 ;;
        esac
    fi
}

# Choose from list
choose() {
    local prompt_msg="$1"
    shift
    local options=("$@")

    if command_exists gum; then
        gum choose --header "$prompt_msg" "${options[@]}"
    else
        echo "$prompt_msg"
        select opt in "${options[@]}"; do
            if [ -n "$opt" ]; then
                echo "$opt"
                break
            fi
        done
    fi
}

# Expand tilde in path
expand_tilde() {
    local path="$1"
    echo "${path/#\~/$HOME}"
}

# Get worktree path
get_worktree_path() {
    local repo="$1"
    local topic="$2"
    local base_path
    base_path=$(expand_tilde "${WORKTREE_PATH:-$HOME/.worktrees}")

    echo "$base_path/$repo/$topic"
}

# Create tmux session
create_tmux_session() {
    local session_name="$1"
    local worktree_path="$2"
    local launch_agent="${3:-true}"

    # Create detached session
    tmux new-session -d -s "$session_name" -c "$worktree_path"

    # Launch agent if requested
    if [ "$launch_agent" = "true" ]; then
        local agent_cmd="${WORKTREE_AGENT_CMD:-claude}"
        if command_exists "${agent_cmd%% *}"; then
            tmux send-keys -t "$session_name" "$agent_cmd" C-m
        else
            log_warn "Agent command '$agent_cmd' not found"
        fi
    fi
}

# Switch to session
switch_to_session() {
    local session_name="$1"

    if [ -n "$TMUX" ]; then
        tmux switch-client -t "$session_name"
    else
        tmux attach-session -t "$session_name"
    fi
}

# Get current session name
get_current_session() {
    tmux display-message -p '#S'
}

# Display in tmux popup or split
display_in_tmux() {
    local command="$1"

    # Use popup if tmux version supports it (3.2+)
    if tmux display-message -p '#{version}' | awk '{exit !($1 >= 3.2)}'; then
        tmux display-popup -E -w 90% -h 90% "$command"
    else
        # Fallback to split pane
        tmux split-window -h -l 50% "$command"
    fi
}

# Source metadata library
source_metadata_lib() {
    local metadata_lib="$PLUGIN_DIR/lib/metadata.sh"
    if [ -f "$metadata_lib" ]; then
        source "$metadata_lib"
    else
        log_error "Metadata library not found: $metadata_lib"
        return 1
    fi
}
