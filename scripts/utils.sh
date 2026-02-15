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

# Find agent PID in pane's process tree
# Handles native binaries (bash → claude) and node/bun-wrapped agents (bash → node → codex)
find_agent_pid() {
    local pane_pid="$1"
    local agent_process="$2"
    local pid

    # Direct child (native binaries like claude)
    pid=$(pgrep -P "$pane_pid" -x "$agent_process" 2>/dev/null | head -1)
    if [ -n "$pid" ]; then
        echo "$pid"
        return 0
    fi

    # Grandchild (node/bun-wrapped agents like codex, gemini)
    local child_pids
    child_pids=$(pgrep -P "$pane_pid" 2>/dev/null)
    for cpid in $child_pids; do
        pid=$(pgrep -P "$cpid" -x "$agent_process" 2>/dev/null | head -1)
        if [ -n "$pid" ]; then
            echo "$pid"
            return 0
        fi
    done

    return 1
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
        # Output prompt to stderr to avoid capturing it
        echo -n "$message" >&2
        if [ -n "$default" ]; then
            echo -n " [$default]" >&2
        fi
        echo -n ": " >&2
        # Read input - try /dev/tty first, fall back to stdin
        local response
        if [ -r /dev/tty ]; then
            read -r response </dev/tty
        else
            read -r response
        fi
        # Output only the response to stdout
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
        echo -n "$message [y/N]: " >&2
        local response
        if [ -r /dev/tty ]; then
            read -r response </dev/tty
        else
            read -r response
        fi
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

# Select branch with arrow key navigation
select_branch() {
    local repo_path="$1"
    local allow_new="${2:-true}"

    # Fallback to simple prompt if fzf not available
    if ! command_exists fzf; then
        log_warn "fzf not available, using simple input"
        prompt "Branch name"
        return
    fi

    # Get branches sorted by recent activity
    local branches
    branches=$(cd "$repo_path" && \
        git for-each-ref --sort=-committerdate refs/heads/ \
            --format='%(refname:short)|%(committerdate:relative)|%(subject)' 2>/dev/null)

    if [ -z "$branches" ]; then
        log_warn "No branches found in repository"
        prompt "Branch name"
        return
    fi

    # Format branches for display (align columns)
    local formatted_branches
    formatted_branches=$(echo "$branches" | awk -F'|' '{
        branch = $1
        date = $2
        subject = substr($3, 1, 50)
        printf "%-30s  %-20s  %s\n", branch, date, subject
    }')

    # Use fzf with preview
    local selected
    selected=$(echo "$formatted_branches" | fzf \
        --ansi \
        --header="↑↓ Navigate | Enter: Select | Type: Filter/New Branch | Esc: Cancel" \
        --layout=reverse \
        --preview="cd '$repo_path' && git log --oneline --graph --color=always {1} 2>/dev/null | head -20" \
        --preview-window=right:60%:wrap \
        --bind='esc:cancel' \
        --print-query \
        --delimiter=' ' \
        --nth=1 \
        --with-nth=1,2,3)

    # fzf with --print-query outputs query on first line, selection on second
    # If user types and presses Enter without selecting, only query is returned
    # If user selects a branch, both query and selection are returned
    local query selection
    if [ -n "$selected" ]; then
        query=$(echo "$selected" | head -1)
        selection=$(echo "$selected" | tail -1)

        # If selection is empty or same as query, user typed a branch name
        if [ -z "$selection" ] || [ "$query" = "$selection" ]; then
            echo "$query"
        else
            # Extract branch name (first column)
            echo "$selection" | awk '{print $1}'
        fi
    else
        # User cancelled (Esc)
        return 1
    fi
}

# Select agent with fzf picker
select_agent() {
    local agent_list="${WORKTREE_AGENT_LIST:-claude}"
    local default_agent="${WORKTREE_AGENT_CMD:-claude}"

    # Parse comma-separated list into array
    local agents=()
    IFS=',' read -ra agents <<< "$agent_list"

    # Filter to only installed agents
    local available=()
    for agent in "${agents[@]}"; do
        agent=$(echo "$agent" | xargs)  # trim whitespace
        if command_exists "$agent"; then
            available+=("$agent")
        fi
    done

    # No agents available
    if [ ${#available[@]} -eq 0 ]; then
        log_warn "No agents from list are installed"
        return 1
    fi

    # Single agent — auto-select, skip fzf
    if [ ${#available[@]} -eq 1 ]; then
        echo "${available[0]}"
        return 0
    fi

    # Build display list with default tag
    local display_list=""
    for agent in "${available[@]}"; do
        if [ "$agent" = "$default_agent" ]; then
            display_list+="${agent} (default)"$'\n'
        else
            display_list+="${agent}"$'\n'
        fi
    done
    # Remove trailing newline
    display_list="${display_list%$'\n'}"

    # Use fzf to pick
    local selected
    selected=$(echo "$display_list" | fzf \
        --ansi \
        --header="Select agent | Enter: Select | Esc: Cancel" \
        --layout=reverse \
        --height=~10 \
        --no-info \
        --bind='esc:cancel')

    if [ -z "$selected" ]; then
        return 1
    fi

    # Strip "(default)" tag if present
    echo "$selected" | awk '{print $1}'
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
    local agent_cmd="${4:-}"
    local topic="${5:-}"

    # Create detached session
    tmux new-session -d -s "$session_name" -c "$worktree_path"

    # Set window name to topic if provided
    if [ -n "$topic" ]; then
        tmux rename-window -t "$session_name:0" "$topic"
    fi

    # Launch agent if requested
    if [ "$launch_agent" = "true" ] && [ -n "$agent_cmd" ]; then
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
