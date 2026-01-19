#!/usr/bin/env bash

# Get script directory and source utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"

# Colors
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Detect context
detect_context() {
    local context=""

    # Check if in worktree session
    local current_session
    current_session=$(get_current_session 2>/dev/null)

    if [ -n "$current_session" ] && session_in_metadata "$current_session"; then
        context="worktree"
    fi

    # Check if in git repo
    if is_git_repo; then
        if [ "$context" = "worktree" ]; then
            context="worktree-git"
        else
            context="git"
        fi
    fi

    # Default context
    if [ -z "$context" ]; then
        context="default"
    fi

    echo "$context"
}

# Get current session info if in worktree
get_session_info() {
    local current_session
    current_session=$(get_current_session 2>/dev/null)

    if [ -n "$current_session" ] && session_in_metadata "$current_session"; then
        local branch topic repo
        branch=$(get_session_field "$current_session" "branch")
        topic=$(get_session_field "$current_session" "topic")
        repo=$(get_session_field "$current_session" "repo")

        echo -e "${BOLD}${CYAN}Current Session:${NC} ${GREEN}$current_session${NC}"
        echo -e "${DIM}  Repo: $repo | Branch: $branch | Topic: $topic${NC}"
        echo ""
    fi
}

# Show main shortcuts
show_main_shortcuts() {
    echo -e "${BOLD}${BLUE}━━━ Tmux Worktree Agent ━━━${NC}"
    echo ""
    echo -e "${YELLOW}Session Management:${NC}"
    echo -e "  ${CYAN}C-a C-w${NC}    Create new worktree (full mode - choose branch + topic)"
    echo -e "  ${CYAN}C-a W${NC}      Quick create (use current branch or create new)"
    echo -e "  ${CYAN}C-a w${NC}      Browse/switch worktree sessions"
    echo -e "  ${CYAN}C-a D${NC}      Edit session description (for AI agent context)"
    echo -e "  ${CYAN}C-a K${NC}      Kill current worktree + session"
    echo -e "  ${CYAN}C-a R${NC}      Reconcile/refresh metadata"
    echo ""
}

# Show git shortcuts
show_git_shortcuts() {
    echo -e "${YELLOW}Git Quick Actions:${NC}"
    echo -e "  ${GREEN}git status${NC}              Check repository status"
    echo -e "  ${GREEN}git worktree list${NC}       List all worktrees"
    echo -e "  ${GREEN}git branch${NC}              List branches"
    echo -e "  ${GREEN}git log --oneline -10${NC}  Recent commits"
    echo ""
}

# Show worktree-specific actions
show_worktree_actions() {
    local current_session
    current_session=$(get_current_session 2>/dev/null)

    if [ -n "$current_session" ] && session_in_metadata "$current_session"; then
        echo -e "${YELLOW}Current Session Actions:${NC}"
        echo -e "  ${GREEN}C-a K${NC}              Kill this worktree and session"
        echo -e "  ${GREEN}C-a d${NC}              Detach from session (keep it running)"
        echo -e "  ${GREEN}C-a w${NC}              Switch to another worktree"
        echo -e "  ${GREEN}git push${NC}           Push changes to remote"
        echo ""
    fi
}

# Show available tools
show_available_tools() {
    echo -e "${YELLOW}Available Tools:${NC}"

    local tools=()
    command_exists claude && tools+=("${GREEN}claude${NC} - AI coding assistant")
    command_exists gum && tools+=("${GREEN}gum${NC} - Beautiful prompts")
    command_exists fzf && tools+=("${GREEN}fzf${NC} - Fuzzy finder")
    command_exists bat && tools+=("${GREEN}bat${NC} - Better cat")
    command_exists rg && tools+=("${GREEN}rg${NC} - Fast grep")

    if [ ${#tools[@]} -eq 0 ]; then
        echo -e "  ${DIM}No optional tools detected${NC}"
    else
        for tool in "${tools[@]}"; do
            echo -e "  $tool"
        done
    fi
    echo ""
}

# Show tmux basics
show_tmux_basics() {
    echo -e "${YELLOW}Tmux Basics:${NC}"
    echo -e "  ${CYAN}C-a d${NC}      Detach from session"
    echo -e "  ${CYAN}C-a c${NC}      Create new window"
    echo -e "  ${CYAN}C-a ,${NC}      Rename window"
    echo -e "  ${CYAN}C-a n/p${NC}    Next/Previous window"
    echo -e "  ${CYAN}C-a &${NC}      Kill window"
    echo -e "  ${CYAN}C-a s${NC}      List sessions"
    echo ""
}

# Show context-specific tips
show_tips() {
    local context="$1"

    echo -e "${YELLOW}💡 Tips:${NC}"

    case "$context" in
        worktree*)
            echo -e "  • Each worktree has its own isolated git state"
            echo -e "  • Changes in one worktree don't affect others"
            echo -e "  • Use ${CYAN}C-a w${NC} to quickly switch between topics"
            ;;
        git)
            echo -e "  • Press ${CYAN}C-a C-w${NC} to create a worktree for this repo"
            echo -e "  • Worktrees let you work on multiple branches simultaneously"
            ;;
        *)
            echo -e "  • Navigate to a git repo to see worktree options"
            echo -e "  • Press ${CYAN}C-a ?${NC} anytime to see this help"
            ;;
    esac
    echo ""
}

# Main display
main() {
    clear

    local context
    context=$(detect_context)

    # Header
    echo -e "${BOLD}${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║${NC}     ${BOLD}Context-Aware Helper${NC}                                  ${BOLD}${MAGENTA}║${NC}"
    echo -e "${BOLD}${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Show current session info if applicable
    get_session_info

    # Show context indicator
    case "$context" in
        worktree-git)
            echo -e "${DIM}Context: ${GREEN}●${NC} Worktree Session ${GREEN}●${NC} Git Repository${NC}"
            ;;
        worktree)
            echo -e "${DIM}Context: ${GREEN}●${NC} Worktree Session${NC}"
            ;;
        git)
            echo -e "${DIM}Context: ${GREEN}●${NC} Git Repository${NC}"
            ;;
        *)
            echo -e "${DIM}Context: General${NC}"
            ;;
    esac
    echo ""
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Show main shortcuts
    show_main_shortcuts

    # Show context-specific content
    case "$context" in
        worktree-git|worktree)
            show_worktree_actions
            show_git_shortcuts
            ;;
        git)
            show_git_shortcuts
            ;;
    esac

    # Show tmux basics
    show_tmux_basics

    # Show available tools
    show_available_tools

    # Show tips
    show_tips "$context"

    # Footer
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}Press any key to close...${NC}"

    # Wait for keypress
    read -n 1 -s
}

main
