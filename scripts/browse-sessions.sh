#!/usr/bin/env bash

# Browse sessions — tree view grouped by project with live preview
#
# Tree structure (built from metadata):
#   project-name
#     ● session-a
#       ⏎ subtask-1
#       ● subtask-2
#   ────────────────────
#   untracked-repo              ← from $PROJECTS scan
#
# Enter: switch to session (or create worktree for untracked project)
# Ctrl-N: create  Ctrl-T: tasks  Ctrl-D: kill  Ctrl-R: refresh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"
source "$SCRIPT_DIR/status-agents.sh"

trap 'rc=$?; if [ $rc -ne 0 ]; then sleep 1.5; fi; exit $rc' EXIT

if ! check_dependencies; then
    exit 1
fi

# ── Colors ──────────────────────────────────────────────────────────────

DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ─────────────────────────────────────────────────────────────

status_display_icon() {
    case "$1" in
        prompt) printf "${YELLOW}⏎${NC}" ;;
        active) printf "${GREEN}●${NC}" ;;
        dead)   printf "${RED}✗${NC}" ;;
        off)    printf "${DIM}◌${NC}" ;;
        *)      printf "${DIM} ${NC}" ;;
    esac
}

# ── Build tree ─────────────────────────────────────────────────────────
#
# Each line: <display>\t<session_name>\t<type>\t<repo_path>
# fzf shows display (--with-nth=1), actions use {2},{3},{4}

build_tree() {
    local search_dir="${PROJECTS:-$HOME/localGit}"

    # Repos from metadata
    local meta_repos=()
    if [ -f "$METADATA_FILE" ]; then
        while IFS= read -r repo; do
            [ -z "$repo" ] && continue
            meta_repos+=("$repo")
        done < <(jq -r '[.[].repo] | unique | .[]' "$METADATA_FILE" 2>/dev/null)
    fi

    for repo in "${meta_repos[@]}"; do
        # Project header with status counts
        local count=0 cp=0 ca=0
        while IFS= read -r session; do
            [ -z "$session" ] && continue
            ((count++)) || true
            local st
            st=$(agent_status_icon "$session")
            case "$st" in prompt) ((cp++)) || true ;; active) ((ca++)) || true ;; esac
        done < <(find_sessions_by_repo "$repo")

        local suffix=""
        [ $cp -gt 0 ] && suffix+=" ${YELLOW}⏎${cp}${NC}"
        [ $ca -gt 0 ] && suffix+=" ${GREEN}●${ca}${NC}"
        [ $count -gt 0 ] && [ $cp -eq 0 ] && [ $ca -eq 0 ] && suffix+=" ${DIM}${count}${NC}"

        local repo_path=""
        repo_path=$(jq -r --arg r "$repo" \
            '[.[] | select(.repo == $r) | .main_repo_path] | first // empty' \
            "$METADATA_FILE" 2>/dev/null)

        printf " ${BOLD}%s${NC}%b\t\tproject\t%s\n" "$repo" "$suffix" "$repo_path"

        # Top-level sessions (no parent, or parent not in this repo's sessions)
        local repo_sessions=()
        while IFS= read -r s; do
            [ -n "$s" ] && repo_sessions+=("$s")
        done < <(find_sessions_by_repo "$repo")

        for session in "${repo_sessions[@]}"; do
            local parent
            parent=$(get_session_field "$session" "parent_session")
            # Session is top-level if parent is empty or not a session in this repo
            local is_child=false
            if [ -n "$parent" ]; then
                for rs in "${repo_sessions[@]}"; do
                    [ "$parent" = "$rs" ] && is_child=true && break
                done
            fi
            $is_child && continue

            local status s_icon label description
            status=$(agent_status_icon "$session")
            s_icon=$(status_display_icon "$status")
            label="${session#${repo}-}"
            [ ${#label} -gt 28 ] && label="${label:0:27}~"
            description=$(get_session_field "$session" "description")
            local desc_part=""
            [ -n "$description" ] && desc_part=" ${DIM}${description:0:30}${NC}"

            printf "   %b %s%b\t%s\tsession\t%s\n" "$s_icon" "$label" "$desc_part" "$session" "$repo_path"

            # Child sessions (subtasks of this session)
            for child in "${repo_sessions[@]}"; do
                local child_parent
                child_parent=$(get_session_field "$child" "parent_session")
                [ "$child_parent" != "$session" ] && continue

                local cs ci cl cd
                cs=$(agent_status_icon "$child")
                ci=$(status_display_icon "$cs")
                cl="${child#${repo}-}"
                [ ${#cl} -gt 26 ] && cl="${cl:0:25}~"
                cd=$(get_session_field "$child" "description")
                local cdp=""
                [ -n "$cd" ] && cdp=" ${DIM}${cd:0:28}${NC}"

                printf "     %b %s%b\t%s\tsubtask\t%s\n" "$ci" "$cl" "$cdp" "$child" "$repo_path"
            done
        done
    done

    # Separator
    printf "${DIM}────────────────────────────────${NC}\t\tseparator\t\n"

    # Untracked projects
    if [ -d "$search_dir" ]; then
        while IFS= read -r git_dir; do
            local upath="${git_dir%/.git}"
            local uname
            uname=$(get_repo_name "$upath")
            local skip=false
            for mr in "${meta_repos[@]}"; do
                [ "$mr" = "$uname" ] && skip=true && break
            done
            $skip && continue
            printf " ${DIM}%s${NC}\t%s\tuntracked\t%s\n" "$uname" "$uname" "$upath"
        done < <(find "$search_dir" -maxdepth 2 -name .git 2>/dev/null | sort)
    fi
}

# ── List mode (for fzf reload) ────────────────────────────────────────

if [ "${1:-}" = "--list" ]; then
    build_tree
    exit 0
fi

# ── Main ───────────────────────────────────────────────────────────────

main() {
    # Auto-cleanup stale metadata
    local cleaned
    cleaned=$(clean_orphaned_metadata)
    [ "$cleaned" -gt 0 ] && log_info "Cleaned $cleaned stale entries"

    # Detect current repo for Ctrl-N context
    local current_repo_path=""
    current_repo_path=$(git rev-parse --show-toplevel 2>/dev/null) || true

    local preview_script="$SCRIPT_DIR/browse-preview.sh"

    while true; do
        local tree
        tree=$(build_tree)

        if [ -z "$tree" ]; then
            log_warn "No projects found"
            log_info "Create a worktree with: prefix + C-w"
            echo ""
            read -n 1 -s -r -p "Press any key to close..." < /dev/tty
            exit 0
        fi

        local result
        result=$(echo -e "$tree" | fzf \
            --ansi \
            --no-sort \
            --layout=reverse \
            --header="Enter:jump ^N:create ^T:tasks ^D:kill ^R:refresh" \
            --header-first \
            --prompt="" \
            --pointer="▸" \
            --delimiter=$'\t' \
            --with-nth=1 \
            --height=100% \
            --preview="bash '$preview_script' {2} {3} {4}" \
            --preview-window=right:45%:wrap \
            --expect=enter \
            --bind "ctrl-n:execute(tmux display-popup -E -w 85% -h 85% -d '${current_repo_path:-~}' '$SCRIPT_DIR/create-worktree.sh')+reload(bash '$SCRIPT_DIR/browse-sessions.sh' --list)" \
            --bind "ctrl-t:execute(tmux display-popup -E -w 95% -h 95% -d '${current_repo_path:-~}' '$SCRIPT_DIR/task-selector.sh')+reload(bash '$SCRIPT_DIR/browse-sessions.sh' --list)" \
            --bind "ctrl-d:execute(tmux display-popup -E -w 85% -h 85% '$SCRIPT_DIR/kill-worktree.sh' {2})+reload(bash '$SCRIPT_DIR/browse-sessions.sh' --list)" \
            --bind "ctrl-r:reload(bash '$SCRIPT_DIR/browse-sessions.sh' --list)" \
        ) || break

        local key selected_line
        key=$(echo "$result" | head -1)
        selected_line=$(echo "$result" | tail -1)

        if [ "$key" = "enter" ] && [ -n "$selected_line" ]; then
            local sel_session sel_type sel_path
            sel_session=$(echo "$selected_line" | awk -F'\t' '{print $2}')
            sel_type=$(echo "$selected_line" | awk -F'\t' '{print $3}')
            sel_path=$(echo "$selected_line" | awk -F'\t' '{print $4}')

            case "$sel_type" in
                session|subtask)
                    if [ -n "$sel_session" ]; then
                        if tmux has-session -t "$sel_session" 2>/dev/null; then
                            tmux switch-client -t "$sel_session" && break
                        else
                            # Ghost session — tmux session gone but metadata/worktree remain
                            local wt_path
                            wt_path=$(get_session_field "$sel_session" "worktree_path")
                            if [ -d "$wt_path" ]; then
                                # Worktree exists — offer to recreate session
                                local choice
                                choice=$(printf "Recreate session\nDelete worktree & metadata\nCancel" \
                                    | fzf --height=6 --layout=reverse \
                                          --header="Session '$sel_session' is gone. Worktree still exists." \
                                          --prompt="▸ ") || { continue; }
                                case "$choice" in
                                    "Recreate session")
                                        local branch repo_name agent_cmd
                                        branch=$(get_session_field "$sel_session" "branch")
                                        repo_name=$(get_session_field "$sel_session" "repo")
                                        agent_cmd=$(get_session_field "$sel_session" "agent_cmd")
                                        tmux new-session -d -s "$sel_session" -c "$wt_path"
                                        if [ -n "$agent_cmd" ] && command -v "${agent_cmd%% *}" &>/dev/null; then
                                            tmux send-keys -t "$sel_session" "$agent_cmd" C-m
                                        fi
                                        tmux switch-client -t "$sel_session" && break
                                        ;;
                                    "Delete worktree & metadata")
                                        local main_repo
                                        main_repo=$(get_session_field "$sel_session" "main_repo_path")
                                        if [ -n "$main_repo" ] && [ -d "$main_repo" ]; then
                                            (cd "$main_repo" && git worktree remove --force "$wt_path" 2>/dev/null) || rm -rf "$wt_path"
                                        else
                                            rm -rf "$wt_path"
                                        fi
                                        delete_session "$sel_session"
                                        continue
                                        ;;
                                    *) continue ;;
                                esac
                            else
                                # Both gone — clean up metadata
                                delete_session "$sel_session"
                                continue
                            fi
                        fi
                    fi
                    ;;
                untracked)
                    if [ -n "$sel_session" ] && [ -n "$sel_path" ]; then
                        # Run create-worktree inline (we're already in a popup)
                        (cd "$sel_path" && bash "$SCRIPT_DIR/create-worktree.sh")
                    fi
                    break
                    ;;
                project|separator)
                    continue
                    ;;
            esac
        fi

        break
    done
}

main
