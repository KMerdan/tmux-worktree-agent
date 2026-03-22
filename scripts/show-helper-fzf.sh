#!/usr/bin/env bash

# show-helper-fzf.sh - FZF-style interactive helper with clear UX distinction
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"

# Colors for output
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
NC='\033[0m'

# Detect context
detect_context() {
    local context=""
    local current_session
    current_session=$(get_current_session 2>/dev/null)

    if [ -n "$current_session" ] && session_in_metadata "$current_session"; then
        context="worktree"
    fi

    if is_git_repo; then
        if [ "$context" = "worktree" ]; then
            context="worktree-git"
        else
            context="git"
        fi
    fi

    [ -z "$context" ] && context="default"
    echo "$context"
}

# Generate command list with human-readable actions on left
generate_command_list() {
    local context="$1"

    # === EXECUTABLE COMMANDS (Git Quick View) ===
    if [ "$context" = "git" ] || [ "$context" = "worktree-git" ]; then
        echo "exec|▶ Check working tree status|git status|Shows staged, unstaged, and untracked files"
        echo "exec|▶ List all worktrees|git worktree list|Shows all worktrees and their locations"
        echo "exec|▶ List all branches|git branch|Shows local and remote branches"
        echo "exec|▶ Show recent commits|git log --oneline -10|Last 10 commits in compact format"
        echo "exec|▶ Show unstaged changes|git diff|Displays changes not yet staged for commit"
        echo "---"
    fi

    # === REFERENCE: Worktree Agent ===
    echo "ref|📖 Create new worktree (full)|C-a C-w|Full wizard with branch selection and topic naming"
    echo "ref|📖 Create worktree (quick)|C-a W|Uses current branch - faster workflow"
    echo "ref|📖 Browse/switch sessions|C-a w|FZF browser to navigate all worktree sessions"
    echo "ref|📖 Edit session description|C-a D|Add/update context description for AI agents"
    echo "ref|📖 Kill current worktree|C-a K|Removes worktree, tmux session, and metadata"
    echo "ref|📖 Fix orphaned sessions|C-a R|Automatically reconcile sessions and worktrees"
    echo "ref|📖 Register existing session|C-a A|Register current tmux session into plugin metadata"
    echo "ref|📖 Window/pane operations|C-a O|Interactive popup menu for window/pane management"
    echo "---"

    # === REFERENCE: Task Workflow ===
    echo "ref|📖 Task Prompts|C-a G|Menu: Generate task.md / Merge completed tasks / Update constraints"
    echo "ref|📖 Task Selector|C-a T|Browse markdown files, validate task format, multi-select tasks, batch-spawn worktree sessions"
    echo "---"

    # === REFERENCE: Tmux Essentials ===
    echo "ref|📖 Detach from session|C-a d|Detaches client, session keeps running in background"
    echo "ref|📖 Create new window|C-a c|Creates a new window in the current session"
    echo "ref|📖 Rename current window|C-a ,|Changes the name of the current window"
    echo "ref|📖 Navigate windows|C-a n/p|Switches to next (n) or previous (p) window"
    echo "ref|📖 Split pane horizontally|C-a ||Creates side-by-side panes (vertical divider)"
    echo "ref|📖 Split pane vertically|C-a -|Creates top-bottom panes (horizontal divider)"
    echo "ref|📖 Navigate between panes|C-a h/j/k/l|Vim-style: left/down/up/right pane navigation"
    echo "ref|📖 Zoom/unzoom pane|C-r|Toggles current pane fullscreen mode"
    echo "ref|📖 Copy mode: open in vim|C-a [ → v → C-o|Select filepath and open in vim split, or C-o without selection opens current dir"
}

# Execute git command with better output
execute_git_command() {
    local command="$1"
    clear

    echo -e "${GREEN}╭─ Executing: $command ──────────────────────────────────╮${NC}"
    echo -e "${GREEN}╰────────────────────────────────────────────────────────╯${NC}"
    echo ""

    # Execute and capture output
    local output
    output=$(eval "$command" 2>&1)

    if [ $? -eq 0 ]; then
        echo "$output"
    else
        echo -e "${YELLOW}⚠ Command completed with errors:${NC}"
        echo "$output"
    fi

    echo ""
    echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}💡 Press Enter to run again, or any other key to return${NC}"

    # Read key - if Enter, run again
    read -n 1 -s key
    if [ "$key" = "" ]; then
        execute_git_command "$command"
    fi
}

# Main FZF interface
main() {
    local context
    context=$(detect_context)

    # Check if fzf is available
    if ! command -v fzf >/dev/null 2>&1; then
        echo "Error: fzf is required but not installed"
        echo "Install with: brew install fzf"
        exit 1
    fi

    # Generate command list
    local commands
    commands=$(generate_command_list "$context")

    # Custom header based on context
    local header="🔍 Worktree Agent Helper"
    if [ "$context" = "git" ] || [ "$context" = "worktree-git" ]; then
        header="$header | ▶=Executable 📖=Reference | Type to search, Enter to execute, Esc to close"
    else
        header="$header | 📖=Reference keybindings | Type to search, Esc to close"
    fi

    # Create preview script via mktemp to avoid race conditions
    local preview_script
    preview_script=$(mktemp "${TMPDIR:-/tmp}/helper-preview.XXXXXX")
    trap "rm -f '$preview_script'" EXIT
    cat > "$preview_script" << 'PREVIEW_EOF'
#!/usr/bin/env bash
line="$1"

# Skip separators
if [ "$line" = "---" ]; then
    exit 0
fi

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
NC='\033[0m'

IFS='|' read -r type display keybind description <<< "$line"

if [ "$type" = "exec" ]; then
    # Executable command preview
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}▶ EXECUTABLE GIT COMMAND${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}Command:${NC} $keybind"
    echo ""
    echo -e "${BLUE}Description:${NC}"
    echo -e "$description"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}💡 How to use:${NC}"
    echo -e "   • Press ${GREEN}Enter${NC} to execute now"
    echo -e "   • Output will be shown below"
    echo -e "   • Press any key to return to helper"
    echo ""
    echo -e "${GRAY}This is a read-only command - safe to run${NC}"
else
    # Reference item preview
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}📖 KEYBINDING REFERENCE${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}Press:${NC} ${GREEN}$keybind${NC}"
    echo ""
    echo -e "${BLUE}Description:${NC}"
    echo -e "$description"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GRAY}💡 Use this keybinding in your tmux session${NC}"
    echo -e "${GRAY}   (This is reference info, not executable)${NC}"
fi
PREVIEW_EOF
    chmod +x "$preview_script"

    # FZF selection with enhanced preview
    local selection
    selection=$(echo "$commands" | grep -v "^---$" | fzf \
        --height 100% \
        --border rounded \
        --prompt "❯ " \
        --pointer "▶" \
        --marker "✓" \
        --header "$header" \
        --header-first \
        --preview "$preview_script {}" \
        --preview-window right:50%:wrap:border-left \
        --bind 'ctrl-/:toggle-preview' \
        --bind 'tab:toggle-preview' \
        --delimiter '|' \
        --with-nth 2 \
        --ansi \
        --cycle \
        --reverse \
        --color 'pointer:green,marker:green,header:cyan')

    # Handle selection
    if [ -n "$selection" ]; then
        IFS='|' read -r type display keybind description <<< "$selection"

        # Only execute if it's an executable command
        if [ "$type" = "exec" ]; then
            execute_git_command "$keybind"
            # Reopen helper after viewing output
            exec "$0"
        fi
    fi
}

main
