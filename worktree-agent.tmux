#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default configuration
default_worktree_path="$HOME/.worktrees"
default_agent_cmd="claude"
default_agent_list="claude"
default_auto_agent="on"
default_browser_key="w"
default_create_key="C-w"
default_quick_create_key="W"
default_kill_key="K"
default_refresh_key="R"
default_helper_key="?"
default_description_key="D"
default_cleanup_key="C"
default_ops_key="O"

# Get tmux options with defaults
get_tmux_option() {
    local option="$1"
    local default_value="$2"
    local option_value
    option_value=$(tmux show-option -gqv "$option")
    if [ -z "$option_value" ]; then
        echo "$default_value"
    else
        echo "$option_value"
    fi
}

# Expand tilde in path
expand_tilde() {
    local path="$1"
    echo "${path/#\~/$HOME}"
}

# Configuration
worktree_path=$(expand_tilde "$(get_tmux_option "@worktree-path" "$default_worktree_path")")
agent_cmd=$(get_tmux_option "@worktree-agent-cmd" "$default_agent_cmd")
agent_list=$(get_tmux_option "@worktree-agent-list" "$default_agent_list")
auto_agent=$(get_tmux_option "@worktree-auto-agent" "$default_auto_agent")
browser_key=$(get_tmux_option "@worktree-browser-key" "$default_browser_key")
create_key=$(get_tmux_option "@worktree-create-key" "$default_create_key")
quick_create_key=$(get_tmux_option "@worktree-quick-create-key" "$default_quick_create_key")
kill_key=$(get_tmux_option "@worktree-kill-key" "$default_kill_key")
refresh_key=$(get_tmux_option "@worktree-refresh-key" "$default_refresh_key")
helper_key=$(get_tmux_option "@worktree-helper-key" "$default_helper_key")
description_key=$(get_tmux_option "@worktree-description-key" "$default_description_key")
cleanup_key=$(get_tmux_option "@worktree-cleanup-key" "$default_cleanup_key")
ops_key=$(get_tmux_option "@worktree-ops-key" "$default_ops_key")

# Export configuration for scripts
tmux set-environment -g WORKTREE_PATH "$worktree_path"
tmux set-environment -g WORKTREE_AGENT_CMD "$agent_cmd"
tmux set-environment -g WORKTREE_AGENT_LIST "$agent_list"
tmux set-environment -g WORKTREE_AUTO_AGENT "$auto_agent"
tmux set-environment -g WORKTREE_PLUGIN_DIR "$CURRENT_DIR"

# Set up keybindings (using larger popups for better visibility)
tmux bind-key "$browser_key" display-popup -E -w 95% -h 95% -d "#{pane_current_path}" "$CURRENT_DIR/scripts/browse-sessions.sh"
tmux bind-key "$create_key" display-popup -E -w 85% -h 85% -d "#{pane_current_path}" "$CURRENT_DIR/scripts/create-worktree.sh"
tmux bind-key "$quick_create_key" display-popup -E -w 85% -h 85% -d "#{pane_current_path}" "$CURRENT_DIR/scripts/create-worktree.sh --quick"
tmux bind-key "$kill_key" display-popup -E -w 85% -h 85% -d "#{pane_current_path}" "$CURRENT_DIR/scripts/kill-worktree.sh"
tmux bind-key "$refresh_key" display-popup -E -w 85% -h 85% -d "#{pane_current_path}" "$CURRENT_DIR/scripts/reconcile.sh"
tmux bind-key "$helper_key" display-popup -E -w 95% -h 95% -d "#{pane_current_path}" "$CURRENT_DIR/scripts/show-helper-fzf.sh"
tmux bind-key "$description_key" display-popup -E -w 85% -h 85% -d "#{pane_current_path}" "$CURRENT_DIR/scripts/session-description.sh prompt"
tmux bind-key "$cleanup_key" display-popup -E -w 95% -h 95% -d "#{pane_current_path}" "$CURRENT_DIR/scripts/cleanup-agents.sh"
tmux bind-key "$ops_key" display-popup -E -w 95% -h 95% -d "#{pane_current_path}" "$CURRENT_DIR/scripts/window-pane-ops.sh"

# Ensure directories exist
mkdir -p "$worktree_path"
mkdir -p "$CURRENT_DIR/lib"

# Initialize metadata if it doesn't exist
metadata_file="$CURRENT_DIR/.worktree-sessions.json"
if [ ! -f "$metadata_file" ]; then
    echo '{}' > "$metadata_file"
fi

# Append agent status to status bar (after theme plugins have set status-right)
tmux set -g status-interval 5
tmux set -ag status-right " #[fg=#89b4fa]#($CURRENT_DIR/scripts/status-agents.sh)"
tmux set -g status-right-length 200
