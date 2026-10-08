---
title: Window & Workspace Actions
description: Operate on specific windows by opaque ID and manage workspaces by name, including cross-monitor moves.
sidebar:
  order: 4
---

## Window Actions

Operate on specific windows by their session-scoped opaque ID.

```
omniwmctl window <action> <opaque-id>
omniwmctl window move-to-workspace <opaque-id> <workspace>
omniwmctl window move-column-to-index <opaque-id> <number>
omniwmctl window move-column <opaque-id> <left|right|up|down>
omniwmctl window set-container-primary-span <opaque-id> <size-change>
omniwmctl window set-window-primary-span <opaque-id> <size-change>
omniwmctl window set-window-secondary-span <opaque-id> <size-change>
omniwmctl window cycle-window-primary-span <opaque-id> <forward|backward>
omniwmctl window cycle-window-secondary-span <opaque-id> <forward|backward>
omniwmctl window assign-to-scratchpad <opaque-id> <number>
```

| Action | Description |
|--------|-------------|
| `focus` | Focus a managed window by opaque ID |
| `navigate` | Navigate to a managed window (switches workspace if needed) |
| `summon-right` | Summon a window to the right of the currently focused window. Floating targets return `window_action_failed` |
| `close` | Close a managed window through its close button; returns `window_action_failed` when the window has no close button or refuses the press. The window leaves the managed set only when macOS reports it destroyed |
| `move-to-workspace` | Move a window to a workspace by raw workspace ID or unambiguous display name. Focus stays where it is; if the window is the focused one, the configured follow-focus behavior applies. A window already on the target returns `no_change`; an ambiguous display name returns `invalid_arguments` |
| `move-column-to-first` | Move the window's column to the first position. Niri only |
| `move-column-to-last` | Move the window's column to the last position. Niri only |
| `move-column-to-index` | Move the window's column to a one-based column index. Niri only |
| `move-column` | Move the window's column one step `left`, `right`, `up`, or `down`. Niri only |
| `toggle-container-full-primary-span` | Toggle full primary span for the window's column. Niri only |
| `set-container-primary-span` | Set or adjust the primary span of the window's column. Niri only |
| `set-window-primary-span` | Set or adjust the window's primary span. Niri only |
| `cycle-window-primary-span` | Cycle the window's primary span preset `forward` or `backward`. Niri only |
| `set-window-secondary-span` | Set or adjust the window's secondary span within its column. Niri only |
| `reset-window-secondary-span` | Reset the window's secondary span within its column. Niri only |
| `cycle-window-secondary-span` | Cycle the window's secondary span preset `forward` or `backward`. Niri only |
| `toggle-column-tabbed` | Toggle tabbed display for the window's column. Niri only |
| `toggle-floating` | Toggle the window between tiled and floating. A floating window on a Niri workspace is re-tiled as a new column after the focused column, without taking focus |
| `assign-to-scratchpad` | Assign the window to a numbered scratchpad slot (1-10); if it is already in that slot, remove it from the scratchpad and tile it again. A hidden member is released onto the active workspace of the window's monitor, as its own new column |

The actions from `move-column-to-first` onward act on the given window or its column without changing focus or scrolling the viewport: the focused window keeps its on-screen position, except when the existing relayout clamps the view to the content edges (empty space would be exposed past the first or last column) or the workspace enters single-window layout. An action on a window in the focused window's own column behaves like the matching focused-column command for viewport purposes. `<size-change>` accepts fixed pixels (`100`), proportions (`50%`), fixed deltas (`+10`), or proportional deltas (`-10%`).

Window IDs are session-scoped. They become stale after OmniWM restarts. Obtain IDs from query results (e.g., `omniwmctl query windows`).

---

## Window Marks

Marks give live managed windows unique names across workspaces. They last until the window closes or OmniWM quits; they are not saved in settings. Unlike window actions by opaque ID, mark actions use the name you choose:

| Action | Description |
|--------|-------------|
| `window mark set <name>` | Mark the focused managed window. Reusing its own name succeeds; a name on another window returns `duplicate_mark` |
| `window mark list [--json]` | List marks with their current workspace, app, and window title |
| `window mark focus <name>` | Navigate to the marked window, switching workspaces or unhiding its app as needed |
| `window mark summon <name>` | Move a marked tiled window to the right of the focused window. Floating targets return `window_action_failed`; hidden targets return `hidden_window` |
| `window mark remove <name>` | Remove a mark by name |

`set` and `summon` need a focused managed window. Use `omniwmctl window mark list --json` for the `window-marks` result payload.

---

## Workspace Actions

```
omniwmctl workspace focus-name <name>
omniwmctl workspace move-to-monitor <workspace> <left|right|up|down> [--force]
omniwmctl workspace rename <workspace> <display-name>
```

| Action | Arguments | Description |
|--------|-----------|-------------|
| `focus-name` | `<name>` | Focus a workspace by raw workspace ID or unambiguous configured display name |
| `move-to-monitor` | `<workspace> <left\|right\|up\|down> [--force]` | Move a workspace to an adjacent monitor |
| `rename` | `<workspace> <display-name>` | Set or clear the workspace display name; an empty name restores the raw workspace ID. Returns `no_change` when the label already matches |

Numeric inputs are resolved as raw workspace IDs first. Display-name lookup is a convenience path and fails when multiple workspaces share the same display name. A display name containing a newline is rejected with `invalid_arguments`, and a name starting with `--` cannot be set from the CLI.

Monitor direction is resolved relative to the named workspace's current monitor. Moving a visible workspace transfers its visibility to the destination monitor, and the source monitor selects another eligible workspace. Moving an inactive workspace normally makes it visible on the destination while leaving the source monitor's visible workspace unchanged. If the destination's visible workspace is the current interaction workspace, the moved workspace is assigned there but remains inactive, preserving that interaction instead of replacing it. This action does not swap the two visible workspaces.

If the moved workspace owns the exact focused managed-window token and no incompatible focus transition is pending, that token follows the workspace without a new AX focus request. Otherwise, OmniWM preserves the interaction monitor and any non-managed focus. OmniWM rejects the move when native-fullscreen, macOS-hidden app, scratchpad, or pending focus state cannot be transferred safely.

Configured monitor assignment remains enforced unless `--force` is present. A forced move changes runtime placement without rewriting the workspace's persisted monitor configuration. The override lasts for the current OmniWM process and survives a transient disconnect and reconnect of the same output ID. It clears when the workspace returns to its configured home monitor, when configuration is reapplied, or when OmniWM restarts. If native fullscreen, a macOS-hidden app, a visible scratchpad, or an in-flight managed-focus transition makes rehoming unsafe, configuration reapply defers the clear until that state resolves. Configured workspace restore snapshots continue to prefer the Home Monitor. The flag may appear anywhere after `move-to-monitor`, although help and completion render the canonical trailing form.
