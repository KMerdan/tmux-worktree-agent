#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/utils.sh"
source "$PLUGIN_DIR/lib/metadata.sh"

if ! command_exists tmux; then
    log_error "tmux is required"
    exit 1
fi

if ! command_exists fzf; then
    log_error "fzf is required"
    exit 1
fi

current_session=$(tmux display-message -p '#{session_name}')

choose_action() {
    printf "%s\n" \
        "Combine windows into panes" \
        "Decompose panes into windows" | \
        fzf \
            --layout=reverse \
            --height=~8 \
            --header="Window/Pane Ops | Enter: select | Esc: cancel" \
            --no-info \
            --bind='esc:cancel'
}

build_window_list() {
    tmux list-windows -a \
        -F "#{session_name}|#{window_id}|#{window_active}|#{window_index}|#{window_name}|#{window_panes}|#{pane_id}|#{pane_current_command}|#{pane_current_path}" | \
        while IFS='|' read -r session_name window_id window_active window_index window_name window_panes pane_id pane_cmd pane_path; do
            [ -n "$window_id" ] || continue

            local active_mark path_label
            active_mark=" "
            [ "$window_active" = "1" ] && active_mark="*"

            path_label="${pane_path/#$HOME/~}"
            [ -z "$path_label" ] && path_label="-"

            # Fields:
            # 1 window_id (hidden)
            # 2 active_pane_id (hidden)
            # 3 display title (with session name)
            # 4 display cmd
            # 5 display path
            printf "%s|%s|%s:[%s]%s %s (%s panes)|cmd:%s|path:%s\n" \
                "$window_id" "$pane_id" "$session_name" "$window_index" "$active_mark" "$window_name" "$window_panes" "$pane_cmd" "$path_label"
        done
}

select_target_window() {
    local list selected

    list=$(build_window_list)

    selected=$(echo "$list" | fzf \
        --layout=reverse \
        --header="Select target window | Enter: target | Esc: cancel" \
        --delimiter='|' \
        --with-nth=3,4,5 \
        --preview='tmux list-panes -t {1} -F "[%#{pane_index}] #{?pane_active,*, } #{pane_current_command} | #{pane_title} | #{pane_current_path}"' \
        --preview-window=right:55%:wrap \
        --bind='esc:cancel')

    [ -n "$selected" ] || return 1
    echo "$selected" | awk -F'|' '{print $1 "|" $2}'
}

select_source_windows() {
    local target_window="$1"
    local list selected

    list=$(build_window_list | awk -F'|' -v target="$target_window" '$1 != target')

    [ -n "$list" ] || return 1

    selected=$(echo "$list" | fzf \
        --multi \
        --layout=reverse \
        --header="Select source windows | Tab: mark | Enter: merge into target | Esc: cancel" \
        --delimiter='|' \
        --with-nth=3,4,5 \
        --preview='tmux list-panes -t {1} -F "[%#{pane_index}] #{?pane_active,*, } #{pane_current_command} | #{pane_title} | #{pane_current_path}"' \
        --preview-window=right:55%:wrap \
        --bind='tab:toggle+down,shift-tab:toggle+up,esc:cancel')

    [ -n "$selected" ] || return 1
    echo "$selected" | cut -d'|' -f1
}

combine_windows_into_target() {
    local target_window="$1"
    local target_pane="$2"
    local source_windows="$3"
    local moved_count=0
    local failed_count=0
    local first_error=""
    local join_error=""

    if ! tmux list-panes -t "$target_pane" >/dev/null 2>&1; then
        tmux display-message -d 8000 "Combine failed: target pane no longer exists"
        return 1
    fi

    while IFS= read -r window_id; do
        [ -n "$window_id" ] || continue

        if ! tmux list-windows -t "$window_id" >/dev/null 2>&1; then
            failed_count=$((failed_count + 1))
            [ -z "$first_error" ] && first_error="source window missing: $window_id"
            continue
        fi

        panes=()
        while IFS= read -r pane_id; do
            [ -n "$pane_id" ] || continue
            panes+=("$pane_id")
        done < <(tmux list-panes -t "$window_id" -F "#{pane_id}" || true)

        for pane_id in "${panes[@]}"; do
            [ -n "$pane_id" ] || continue

            if join_error=$(tmux join-pane -d -h -s "$pane_id" -t "$target_pane" 2>&1); then
                moved_count=$((moved_count + 1))
            else
                failed_count=$((failed_count + 1))
                if [ -z "$first_error" ]; then
                    first_error="${join_error:-join-pane failed for $pane_id}"
                fi
            fi
        done
    done <<< "$source_windows"

    tmux select-layout -t "$target_window" tiled >/dev/null 2>&1 || true
    tmux select-window -t "$target_window" >/dev/null 2>&1 || true

    # Update window name to reflect combined content
    rename_window_from_metadata "$target_window" "" 2>/dev/null || true

    if [ "$failed_count" -gt 0 ]; then
        tmux display-message -d 8000 "Merged $moved_count pane(s), failed $failed_count (${first_error})"
    else
        tmux display-message -d 5000 "Merged $moved_count pane(s) into target window"
    fi
}

build_pane_tree() {
    local window_id window_active window_index window_name window_panes pane_id pane_cmd pane_path
    local pane_lines row_id row_desc active_mark path_label

    while IFS='|' read -r window_id window_active window_index window_name window_panes pane_id pane_cmd pane_path; do
        [ -n "$window_id" ] || continue

        active_mark=" "
        [ "$window_active" = "1" ] && active_mark="*"
        path_label="${pane_path/#$HOME/~}"
        [ -z "$path_label" ] && path_label="-"

        printf "W\t%s\t[%s]%s %s (%s panes) | cmd:%s | path:%s\n" \
            "$window_id" "$window_index" "$active_mark" "$window_name" "$window_panes" "$pane_cmd" "$path_label"

        pane_lines=$(tmux list-panes -t "$window_id" \
            -F "#{pane_id}|  - %#{pane_index} #{?pane_active,*, } #{pane_current_command} | #{pane_title} | #{pane_current_path}")

        while IFS='|' read -r row_id row_desc; do
            [ -n "$row_id" ] || continue
            printf "P\t%s\t%s\n" "$row_id" "$row_desc"
        done <<< "$pane_lines"
    done < <(tmux list-windows -t "$current_session" \
        -F "#{window_id}|#{window_active}|#{window_index}|#{window_name}|#{window_panes}|#{pane_id}|#{pane_current_command}|#{pane_current_path}")
}

resolve_selected_panes() {
    local selected_lines="$1"
    local pane_ids selected_windows window_id

    pane_ids=$(echo "$selected_lines" | awk -F'\t' '$1 == "P" { print $2 }')
    selected_windows=$(echo "$selected_lines" | awk -F'\t' '$1 == "W" { print $2 }')

    while IFS= read -r window_id; do
        [ -n "$window_id" ] || continue
        tmux list-panes -t "$window_id" -F "#{pane_id}"
    done <<< "$selected_windows"

    echo "$pane_ids"
}

decompose_selected_panes() {
    local selected panes unique_panes broken_count=0 pane_id

    selected=$(build_pane_tree | fzf \
        --multi \
        --layout=reverse \
        --delimiter=$'\t' \
        --with-nth=3 \
        --header="Select panes (or window rows for all panes) | Tab: mark | Enter: break into windows | Esc: cancel" \
        --bind='tab:toggle+down,shift-tab:toggle+up,esc:cancel')

    [ -n "$selected" ] || return 1

    panes=$(resolve_selected_panes "$selected")
    unique_panes=$(echo "$panes" | awk 'NF' | sort -u)

    [ -n "$unique_panes" ] || {
        log_warn "No panes selected"
        return 1
    }

    while IFS= read -r pane_id; do
        [ -n "$pane_id" ] || continue
        # Detect what's running in this pane before breaking
        local pane_cmd
        pane_cmd=$(tmux display-message -t "$pane_id" -p '#{pane_current_command}' 2>/dev/null) || true
        tmux break-pane -d -s "$pane_id"
        # Name the new window using session metadata + detected command as agent hint
        local new_window_id
        new_window_id=$(tmux display-message -t "$pane_id" -p '#{window_id}' 2>/dev/null) || true
        if [ -n "$new_window_id" ]; then
            rename_window_from_metadata "$new_window_id" "$pane_cmd" 2>/dev/null || true
        fi
        broken_count=$((broken_count + 1))
    done <<< "$unique_panes"

    tmux display-message "Broke $broken_count pane(s) into new window(s)"
}

main() {
    local action target_info target_window source_windows target_pane

    action=$(choose_action)
    [ -n "$action" ] || exit 0

    case "$action" in
        "Combine windows into panes")
            target_info=$(select_target_window) || exit 0
            target_window=$(echo "$target_info" | cut -d'|' -f1)
            target_pane=$(echo "$target_info" | cut -d'|' -f2)
            source_windows=$(select_source_windows "$target_window") || exit 0
            combine_windows_into_target "$target_window" "$target_pane" "$source_windows"
            ;;
        "Decompose panes into windows")
            decompose_selected_panes || exit 0
            ;;
        *)
            exit 0
            ;;
    esac
}

main
