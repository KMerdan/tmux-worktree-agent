#!/usr/bin/env bash

# cleanup-agents.sh - Safe cleanup for Claude Code agent processes
# Part of tmux-worktree-agent plugin

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# Get current tmux session PIDs to protect them
get_current_session_pids() {
    local current_session=""
    if [ -n "$TMUX" ]; then
        current_session=$(tmux display-message -p '#S')
        tmux list-panes -s -t "$current_session" -F '#{pane_pid}' 2>/dev/null | while read -r pane_pid; do
            # Get all child processes of this pane
            pgrep -P "$pane_pid" 2>/dev/null || true
        done
    fi
}

# Get all active tmux session PIDs
get_all_tmux_session_pids() {
    tmux list-panes -a -F '#{pane_pid}' 2>/dev/null | while read -r pane_pid; do
        pgrep -P "$pane_pid" 2>/dev/null || true
    done
}

# Check if a process is active (has recent CPU activity)
is_process_active() {
    local pid=$1
    # Get CPU percentage (2nd field of ps output)
    local cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | xargs)

    # If CPU > 0.0, it's active
    if [ -n "$cpu" ] && [ "$(echo "$cpu > 0.0" | bc 2>/dev/null || echo "0")" = "1" ]; then
        return 0  # Active
    else
        return 1  # Idle
    fi
}

# Check if process is in a tmux session
is_in_tmux_session() {
    local pid=$1
    local tmux_pids
    tmux_pids=$(get_all_tmux_session_pids)

    if echo "$tmux_pids" | grep -q "^${pid}$"; then
        return 0  # In tmux
    else
        return 1  # Not in tmux
    fi
}

# Header
clear
echo -e "${BLUE}╭────────────────────────────────────────────────────────╮${NC}"
echo -e "${BLUE}│${NC}  ${CYAN}Claude Code Agent Cleanup (Safe Mode)${NC}              ${BLUE}│${NC}"
echo -e "${BLUE}╰────────────────────────────────────────────────────────╯${NC}"
echo ""

# Function to display process counts
show_process_counts() {
    local claude_count=$(pgrep -f "claude" 2>/dev/null | wc -l | xargs)
    local old_claude_count=$(ps -eo pid,etime,comm | grep claude | awk '$2 ~ /-/ {print $1}' | wc -l | xargs)
    local orphan_zsh_count=$(ps -eo pid,ppid,comm | awk '$2 == 1 && $3 ~ /zsh/ {print $1}' | wc -l | xargs)
    local current_session_pids=$(get_current_session_pids | wc -l | xargs)

    echo -e "${CYAN}Current Status:${NC}"
    echo -e "  ${GRAY}•${NC} Total Claude processes: ${YELLOW}${claude_count}${NC}"
    echo -e "  ${GRAY}•${NC} Old Claude processes (>1 day): ${YELLOW}${old_claude_count}${NC}"
    echo -e "  ${GRAY}•${NC} Orphaned zsh processes: ${YELLOW}${orphan_zsh_count}${NC}"
    echo -e "  ${GRAY}•${NC} Protected (current session): ${GREEN}${current_session_pids}${NC}"
    echo ""
}

# Function to categorize and show old Claude processes
show_old_claude_processes() {
    echo -e "${CYAN}Claude processes older than 1 day:${NC}"
    echo -e "${GRAY}──────────────────────────────────────────────────────${NC}"

    local protected_pids=$(get_current_session_pids)
    local safe_count=0
    local risky_count=0
    local protected_count=0

    while read -r line; do
        local pid=$(echo "$line" | awk '{print $1}')
        local etime=$(echo "$line" | awk '{print $2}')
        local cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | xargs)

        # Check if this PID is protected (in current session)
        if echo "$protected_pids" | grep -q "^${pid}$"; then
            echo -e "  ${GREEN}●${NC} PID ${YELLOW}${pid}${NC} ${GRAY}(${etime}) [PROTECTED - Current Session]${NC}"
            ((protected_count++))
        # Check if process is in any tmux session
        elif is_in_tmux_session "$pid"; then
            echo -e "  ${YELLOW}▲${NC} PID ${YELLOW}${pid}${NC} ${GRAY}(${etime}) [RISKY - In active tmux session]${NC}"
            ((risky_count++))
        # Check CPU activity
        elif [ -n "$cpu" ] && [ "$(echo "$cpu > 0.0" | bc 2>/dev/null || echo "0")" = "1" ]; then
            echo -e "  ${YELLOW}▲${NC} PID ${YELLOW}${pid}${NC} ${GRAY}(${etime}, CPU: ${cpu}%) [RISKY - Active]${NC}"
            ((risky_count++))
        else
            echo -e "  ${RED}✗${NC} PID ${YELLOW}${pid}${NC} ${GRAY}(${etime}) [SAFE - Idle & orphaned]${NC}"
            ((safe_count++))
        fi
    done < <(ps -eo pid,etime,comm | grep claude | awk '$2 ~ /-/ {print}')

    echo ""
    echo -e "${GRAY}Legend:${NC}"
    echo -e "  ${GREEN}●${NC} Protected (in your current session)"
    echo -e "  ${YELLOW}▲${NC} Risky (active or in other tmux sessions)"
    echo -e "  ${RED}✗${NC} Safe to kill (idle and orphaned)"
    echo ""
    echo -e "${CYAN}Summary:${NC} ${GREEN}${protected_count} protected${NC}, ${YELLOW}${risky_count} risky${NC}, ${RED}${safe_count} safe to kill${NC}"
    echo ""
}

# Function to show recent Claude processes
show_recent_claude_processes() {
    echo -e "${CYAN}Recent Claude processes (less than 1 day old):${NC}"
    echo -e "${GRAY}──────────────────────────────────────────────────────${NC}"

    local protected_pids=$(get_current_session_pids)
    local count=0

    while read -r line; do
        local pid=$(echo "$line" | awk '{print $1}')
        local etime=$(echo "$line" | awk '{print $2}')

        # Mark if protected
        if echo "$protected_pids" | grep -q "^${pid}$"; then
            echo -e "  ${GREEN}●${NC} PID ${YELLOW}${pid}${NC} ${GRAY}(${etime}) [Current Session]${NC}"
        else
            echo -e "  ${GREEN}✓${NC} PID ${YELLOW}${pid}${NC} ${GRAY}(${etime})${NC}"
        fi
        ((count++))

        # Only show first 5 to avoid clutter
        if [ "$count" -ge 5 ]; then
            local remaining=$(ps -eo pid,etime,comm | grep claude | awk '$2 !~ /-/ {print}' | wc -l | xargs)
            local more=$((remaining - 5))
            if [ "$more" -gt 0 ]; then
                echo -e "  ${GRAY}... and ${more} more${NC}"
            fi
            break
        fi
    done < <(ps -eo pid,etime,comm | grep claude | awk '$2 !~ /-/ {print}')

    if [ "$count" -eq 0 ]; then
        echo -e "  ${GRAY}No recent Claude processes found${NC}"
    fi
    echo ""
}

# Function to show orphaned zsh processes
show_orphaned_zsh() {
    echo -e "${CYAN}Orphaned zsh processes (PPID=1):${NC}"
    echo -e "${GRAY}──────────────────────────────────────────────────────${NC}"

    local count=0
    while read -r line; do
        local pid=$(echo "$line" | awk '{print $1}')
        local etime=$(echo "$line" | awk '{print $4}')

        echo -e "  ${RED}✗${NC} PID ${YELLOW}${pid}${NC} ${GRAY}(running for ${etime})${NC}"
        ((count++))
    done < <(ps -eo pid,ppid,comm,etime | awk '$2 == 1 && $3 ~ /zsh/ {print}')

    if [ "$count" -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} No orphaned zsh processes found"
    fi
    echo ""
}

# Function to kill only SAFE old Claude processes
kill_old_claude_safe() {
    echo -e "${YELLOW}Killing only SAFE old Claude processes (idle & orphaned)...${NC}"
    echo ""

    local protected_pids=$(get_current_session_pids)
    local killed=0
    local skipped=0

    while read -r line; do
        local pid=$(echo "$line" | awk '{print $1}')
        local etime=$(echo "$line" | awk '{print $2}')

        # Skip if in current session
        if echo "$protected_pids" | grep -q "^${pid}$"; then
            echo -e "  ${GREEN}↷${NC} Skipped PID ${pid} ${GRAY}(protected - current session)${NC}"
            ((skipped++))
            continue
        fi

        # Skip if in any tmux session
        if is_in_tmux_session "$pid"; then
            echo -e "  ${YELLOW}↷${NC} Skipped PID ${pid} ${GRAY}(in active tmux session)${NC}"
            ((skipped++))
            continue
        fi

        # Skip if actively using CPU
        if is_process_active "$pid"; then
            echo -e "  ${YELLOW}↷${NC} Skipped PID ${pid} ${GRAY}(active CPU usage)${NC}"
            ((skipped++))
            continue
        fi

        # Safe to kill
        if kill "$pid" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Killed PID ${pid} ${GRAY}(${etime})${NC}"
            ((killed++))
        else
            echo -e "  ${RED}✗${NC} Failed to kill PID ${pid}"
        fi
    done < <(ps -eo pid,etime,comm | grep claude | awk '$2 ~ /-/ {print}')

    echo ""
    echo -e "${GREEN}Killed ${killed} processes${NC}, ${YELLOW}Skipped ${skipped} (protected/active)${NC}"
    sleep 1
}

# Function to kill ALL old Claude processes (risky)
kill_old_claude_all() {
    echo -e "${RED}WARNING: This will kill ALL old processes including active ones!${NC}"
    echo -e "${YELLOW}Only current session processes will be protected.${NC}"
    echo ""
    echo -ne "${RED}Are you SURE? Type 'yes' to continue: ${NC}"
    read -r confirm

    if [ "$confirm" != "yes" ]; then
        echo "Cancelled."
        return
    fi

    echo ""
    echo -e "${YELLOW}Killing old Claude processes...${NC}"

    local protected_pids=$(get_current_session_pids)
    local killed=0
    local skipped=0

    while read -r pid; do
        # Only protect current session
        if echo "$protected_pids" | grep -q "^${pid}$"; then
            echo -e "  ${GREEN}↷${NC} Skipped PID ${pid} ${GRAY}(current session)${NC}"
            ((skipped++))
            continue
        fi

        if kill "$pid" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Killed PID ${pid}"
            ((killed++))
        else
            echo -e "  ${RED}✗${NC} Failed to kill PID ${pid}"
        fi
    done < <(ps -eo pid,etime,comm | grep claude | awk '$2 ~ /-/ {print $1}')

    echo ""
    echo -e "${GREEN}Killed ${killed} processes${NC}, ${YELLOW}Protected ${skipped}${NC}"
    sleep 1
}

# Function to kill orphaned zsh processes
kill_orphaned_zsh() {
    echo -e "${YELLOW}Killing orphaned zsh processes...${NC}"

    local killed=0
    while read -r pid; do
        if kill "$pid" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Killed PID ${pid}"
            ((killed++))
        else
            echo -e "  ${RED}✗${NC} Failed to kill PID ${pid}"
        fi
    done < <(ps -eo pid,ppid,comm | awk '$2 == 1 && $3 ~ /zsh/ {print $1}')

    echo ""
    echo -e "${GREEN}Killed ${killed} orphaned zsh processes${NC}"
    sleep 1
}

# Function to check parent process
check_parent_process() {
    local parent_pid=$(ps -eo pid,ppid,comm | grep claude | head -1 | awk '{print $2}')

    if [ -n "$parent_pid" ] && [ "$parent_pid" != "1" ]; then
        local parent_info=$(ps -p "$parent_pid" -o pid,etime,command | tail -1)
        echo -e "${CYAN}Parent Process Info:${NC}"
        echo -e "${GRAY}──────────────────────────────────────────────────────${NC}"
        echo -e "  ${parent_info}"
        echo ""
        echo -e "${YELLOW}Note:${NC} All Claude processes are children of this parent."
        echo -e "      Consider restarting it if you have persistent issues."
        echo ""
    fi
}

# Main interactive menu
show_menu() {
    echo -e "${CYAN}What would you like to do?${NC}"
    echo ""
    echo -e "  ${GREEN}1${NC}) Clean up SAFE old Claude processes (recommended)"
    echo -e "     ${GRAY}Only kills idle processes not in any tmux session${NC}"
    echo ""
    echo -e "  ${YELLOW}2${NC}) Clean up ALL old Claude processes (risky)"
    echo -e "     ${GRAY}Kills all old processes except current session${NC}"
    echo ""
    echo -e "  ${GREEN}3${NC}) Clean up orphaned zsh processes"
    echo ""
    echo -e "  ${GREEN}4${NC}) Show detailed info"
    echo ""
    echo -e "  ${GREEN}q${NC}) Quit"
    echo ""
    echo -n "Choice: "
}

# Main execution
main_interactive() {
    show_process_counts

    local choice
    show_menu
    read -r choice
    echo ""

    case "$choice" in
        1)
            show_old_claude_processes
            echo -ne "${YELLOW}Continue with SAFE cleanup? (y/N): ${NC}"
            read -r confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                kill_old_claude_safe
            else
                echo "Cancelled."
            fi
            ;;
        2)
            show_old_claude_processes
            echo -ne "${RED}Continue with RISKY cleanup? (y/N): ${NC}"
            read -r confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                kill_old_claude_all
            else
                echo "Cancelled."
            fi
            ;;
        3)
            show_orphaned_zsh
            echo -ne "${YELLOW}Continue with cleanup? (y/N): ${NC}"
            read -r confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                kill_orphaned_zsh
            else
                echo "Cancelled."
            fi
            ;;
        4)
            show_old_claude_processes
            show_recent_claude_processes
            show_orphaned_zsh
            check_parent_process
            ;;
        q|Q)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
            exit 1
            ;;
    esac

    echo ""
    echo -e "${BLUE}Final status:${NC}"
    show_process_counts

    echo ""
    echo -e "${GRAY}Press any key to close...${NC}"
    read -n 1 -s
}

main_interactive
