# Scrolling in Tmux Popups

Tmux popups don't support native scrolling, but there are several ways to navigate long content.

## Method 1: Less Pager (Automatic)

Most scripts now pipe through `less` automatically for scrollability.

### Navigation in Less:
- **Arrow keys** (`↑`/`↓`): Scroll line by line
- **Space** / **b**: Page down / Page up
- **j** / **k**: Scroll down / up (vim-style)
- **g** / **G**: Jump to top / bottom
- **Mouse wheel**: Scroll up/down (if mouse enabled)
- **q**: Quit less and return

### Less Status Line:
The bottom shows: `Help (Use arrow keys or mouse to scroll, q to quit) 45%`
- The percentage shows your position in the document

## Method 2: Tmux Copy Mode

For scripts that don't use `less`, use tmux's built-in copy mode:

### Enter Copy Mode:
1. While in a popup, press: **`Ctrl-b [`** (or your prefix + `[`)
2. You'll see `[0/123]` in the top-right corner

### Navigate in Copy Mode:
- **Arrow keys**: Scroll up/down/left/right
- **Page Up/Down**: Scroll by page
- **Ctrl-u / Ctrl-d**: Scroll half-page up/down
- **g / G**: Jump to top/bottom
- **/** : Search forward
- **?** : Search backward
- **n / N**: Next/previous search result

### Exit Copy Mode:
- Press **`q`** or **`Escape`**

## Method 3: Larger Popups

All popups now use 95% of screen size for maximum visibility:
- Helper: 95% width × 95% height
- Cleanup: 95% width × 95% height
- Browser: 95% width × 95% height
- Others: 85% width × 85% height

## Recommended Workflows

### For Help (prefix + ?)
```
prefix + ?                  # Open helper
↑/↓ or mouse wheel          # Scroll with less
q                           # Quit when done
```

### For Cleanup (prefix + C)
```
prefix + C                  # Open cleanup tool
Ctrl-b [                    # Enter copy mode if needed
↑/↓                         # Scroll through processes
q                           # Exit copy mode
Make your choice            # Interact with menu
```

### For Browsing Sessions (prefix + w)
```
prefix + w                  # Open browser (uses fzf)
Ctrl-n/Ctrl-p              # Navigate with fzf
Tab                         # Toggle preview
Preview scrolls with ↑/↓   # Built-in fzf scrolling
```

## Troubleshooting

### Content Cut Off
- **Increase popup size** in `worktree-agent.tmux`:
  ```bash
  tmux bind-key "?" display-popup -E -w 98% -h 98% ...
  ```

### Mouse Not Working
- Enable mouse in tmux:
  ```bash
  set -g mouse on
  ```

### Less Not Scrolling
- Check less is installed:
  ```bash
  which less
  ```
- If not, install it:
  ```bash
  brew install less  # macOS
  ```

## Keyboard Reference Card

| Action | Less | Tmux Copy Mode |
|--------|------|----------------|
| Enter mode | Automatic | `Ctrl-b [` |
| Scroll up | `↑` or `k` | `↑` or `k` |
| Scroll down | `↓` or `j` | `↓` or `j` |
| Page up | `b` or `PgUp` | `PgUp` or `Ctrl-u` |
| Page down | `Space` or `PgDn` | `PgDn` or `Ctrl-d` |
| Top | `g` | `g` |
| Bottom | `G` | `G` |
| Search | `/` | `/` |
| Quit | `q` | `q` or `Esc` |
| Mouse | Scroll wheel | Scroll wheel |

## Tips

1. **Mouse users**: Just use the scroll wheel - works in both less and copy mode
2. **Keyboard users**: Learn `j`/`k` for quick navigation
3. **Search users**: Use `/` to find specific text quickly
4. **Quick browsing**: Use `Space` to jump through pages fast

## Configuration

To customize popup sizes, edit `~/.tmux/plugins/tmux-worktree-agent/worktree-agent.tmux`:

```bash
# Make helper popup full screen
tmux bind-key "?" display-popup -E -w 100% -h 100% -d "#{pane_current_path}" "$CURRENT_DIR/scripts/show-helper-interactive.sh"
```

Adjust `-w` (width) and `-h` (height) as needed:
- `90%` = 90% of screen size
- `100%` = Full screen
- `50` = Fixed 50 characters/lines
