#!/usr/bin/env bash

# show-helper-interactive.sh - Interactive helper with scrolling and executable commands
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
RED='\033[0;31m'
NC='\033[0m'

# Scroll state
SCROLL_OFFSET=0
TERM_HEIGHT=$(tput lines)
TERM_WIDTH=$(tput cols)

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

# Generate help content
generate_help_content() {
    local context="$1"

    # Header
    echo -e "${BOLD}${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}║${NC}     ${BOLD}Interactive Helper${NC}                                    ${BOLD}${MAGENTA}║${NC}"
    echo -e "${BOLD}${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Navigation tip
    echo -e "${DIM}💡 Navigation: ${YELLOW}↑/↓${DIM} scroll, ${YELLOW}PgUp/PgDn${DIM} page, ${YELLOW}s/w/b/l/d${DIM} git view, ${YELLOW}q${DIM} quit${NC}"
    echo ""

    # Show current session info
    get_session_info

    # Context indicator
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

    # Session Management
    echo -e "${BOLD}${BLUE}━━━ Tmux Worktree Agent ━━━${NC}"
    echo ""
    echo -e "${YELLOW}Session Management:${NC}"
    echo -e "  ${CYAN}C-a C-w${NC}    Create new worktree (full mode)"
    echo -e "  ${CYAN}C-a W${NC}      Quick create (use current branch)"
    echo -e "  ${CYAN}C-a w${NC}      Browse/switch sessions"
    echo -e "  ${CYAN}C-a D${NC}      Edit session description"
    echo -e "  ${CYAN}C-a K${NC}      Kill current worktree"
    echo -e "  ${CYAN}C-a R${NC}      Reconcile/refresh metadata"
    echo -e "  ${CYAN}C-a C${NC}      Clean up old agent processes"
    echo -e "  ${CYAN}C-a O${NC}      Window/pane operations popup"
    echo ""

    # Git Quick View (only if in git repo)
    if [ "$context" = "git" ] || [ "$context" = "worktree-git" ]; then
        echo -e "${YELLOW}Git Quick View (press key to execute):${NC}"
        echo -e "  ${GREEN}s${NC}) git status               - Check repo status"
        echo -e "  ${GREEN}w${NC}) git worktree list        - List all worktrees"
        echo -e "  ${GREEN}b${NC}) git branch               - List branches"
        echo -e "  ${GREEN}l${NC}) git log --oneline -10    - Recent commits"
        echo -e "  ${GREEN}d${NC}) git diff                 - Show changes"
        echo ""
    fi

    # Tmux Basics
    echo -e "${YELLOW}Tmux Basics:${NC}"
    echo -e "  ${CYAN}C-a d${NC}      Detach from session"
    echo -e "  ${CYAN}C-a c${NC}      Create new window"
    echo -e "  ${CYAN}C-a ,${NC}      Rename window"
    echo -e "  ${CYAN}C-a n/p${NC}    Next/Previous window"
    echo -e "  ${CYAN}C-a &${NC}      Kill window"
    echo -e "  ${CYAN}C-a s${NC}      List all sessions"
    echo ""

    # Available Tools
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

    # Tips
    echo -e "${YELLOW}💡 Tips:${NC}"
    case "$context" in
        worktree*)
            echo -e "  • Each worktree has its own isolated git state"
            echo -e "  • Use ${CYAN}C-a w${NC} to quickly switch between topics"
            echo -e "  • Changes in one worktree don't affect others"
            ;;
        git)
            echo -e "  • Press ${CYAN}C-a C-w${NC} to create a worktree for this repo"
            echo -e "  • Worktrees let you work on multiple branches simultaneously"
            ;;
        *)
            echo -e "  • Navigate to a git repo to see worktree options"
            ;;
    esac
    echo ""

    # Footer
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Display content with scrolling
display_with_scroll() {
    local context="$1"
    local content

    # Generate content once
    content=$(generate_help_content "$context")

    # Count total lines
    local total_lines
    total_lines=$(echo -e "$content" | wc -l | xargs)
    local max_offset=$((total_lines - TERM_HEIGHT + 3))
    [ "$max_offset" -lt 0 ] && max_offset=0

    while true; do
        clear

        # Display content with offset
        echo -e "$content" | tail -n +$((SCROLL_OFFSET + 1)) | head -n $((TERM_HEIGHT - 2))

        # Status bar
        local percentage=0
        if [ "$total_lines" -gt 0 ]; then
            percentage=$((SCROLL_OFFSET * 100 / total_lines))
        fi
        echo -e "${DIM}Lines $((SCROLL_OFFSET + 1))-$((SCROLL_OFFSET + TERM_HEIGHT - 2))/$total_lines (${percentage}%) | Keys: ${YELLOW}↑/↓${DIM} scroll ${YELLOW}s/w/b/l/d${DIM} git ${YELLOW}q${DIM} quit${NC}"

        # Read single character with escape sequences
        IFS= read -r -s -n 1 key

        # Handle escape sequences (arrow keys)
        if [[ "$key" == $'\x1b' ]]; then
            read -r -s -n 2 -t 0.1 key
            case "$key" in
                '[A') # Up arrow
                    ((SCROLL_OFFSET > 0)) && ((SCROLL_OFFSET--))
                    ;;
                '[B') # Down arrow
                    ((SCROLL_OFFSET < max_offset)) && ((SCROLL_OFFSET++))
                    ;;
                '[5') # Page Up
                    read -r -s -n 1 -t 0.1  # consume ~
                    ((SCROLL_OFFSET -= TERM_HEIGHT / 2))
                    ((SCROLL_OFFSET < 0)) && SCROLL_OFFSET=0
                    ;;
                '[6') # Page Down
                    read -r -s -n 1 -t 0.1  # consume ~
                    ((SCROLL_OFFSET += TERM_HEIGHT / 2))
                    ((SCROLL_OFFSET > max_offset)) && SCROLL_OFFSET=$max_offset
                    ;;
            esac
        else
            case "$key" in
                q|Q)
                    clear
                    exit 0
                    ;;
                j) # Vim down
                    ((SCROLL_OFFSET < max_offset)) && ((SCROLL_OFFSET++))
                    ;;
                k) # Vim up
                    ((SCROLL_OFFSET > 0)) && ((SCROLL_OFFSET--))
                    ;;
                s)
                    if [ "$context" = "git" ] || [ "$context" = "worktree-git" ]; then
                        show_git_output "git status"
                    fi
                    ;;
                w)
                    if [ "$context" = "git" ] || [ "$context" = "worktree-git" ]; then
                        show_git_output "git worktree list"
                    fi
                    ;;
                b)
                    if [ "$context" = "git" ] || [ "$context" = "worktree-git" ]; then
                        show_git_output "git branch"
                    fi
                    ;;
                l)
                    if [ "$context" = "git" ] || [ "$context" = "worktree-git" ]; then
                        show_git_output "git log --oneline -10"
                    fi
                    ;;
                d)
                    if [ "$context" = "git" ] || [ "$context" = "worktree-git" ]; then
                        show_git_output "git diff"
                    fi
                    ;;
            esac
        fi
    done
}

# Show git command output
show_git_output() {
    local cmd="$1"
    clear

    # Header
    echo -e "${BOLD}${CYAN}╭─ Output: $cmd ─────────────────────────────────────╮${NC}"
    echo -e "${BOLD}${CYAN}╰────────────────────────────────────────────────────────╯${NC}"
    echo ""

    # Execute command and show output
    eval "$cmd" 2>&1

    echo ""
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}Press any key to return to helper...${NC}"

    # Wait for keypress
    read -n 1 -s

    # Reset scroll offset when returning
    SCROLL_OFFSET=0
}

# Main
main() {
    local context
    context=$(detect_context)
    display_with_scroll "$context"
}

main
