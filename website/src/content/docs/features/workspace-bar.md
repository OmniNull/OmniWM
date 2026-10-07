---
title: Workspace Bar
description: A floating per-display island that shows your workspaces and their windows at a glance.
sidebar:
  order: 4
---

The workspace bar is a floating island centered along the selected edge of each display. It shows a chip per workspace — with the workspace's name, emoji-friendly — and the icons of the apps open there.

Window hover previews can be turned off separately. Turning off the global Workspace Bar hides it on every monitor, while saved monitor overrides take effect again when it is re-enabled.

## Clicking the bar

- Click a workspace chip to switch to that workspace.
- Click an app icon to focus that window directly.
- When **Deduplicate App Icons** is enabled, multiple windows from one app share a single grouped icon with a count badge; click a grouped icon to open their window list, while a single-window icon focuses that window directly.
- macOS-hidden windows are marked with an eye-slash badge; selecting a hidden window unhides its app and focuses that exact window.
- Non-empty [scratchpad](/features/scratchpads/) slots appear as pills; clicking a pill toggles that scratchpad.

## System Stats

Optionally show a System Stats button that opens a CPU, memory, GPU, disk, and uptime popup. The `Toggle System Stats` hotkey and `omniwmctl command toggle-system-stats` drive the same popup, and both do nothing unless a monitor currently shows that workspace-bar button. See the [CLI reference](/reference/cli/overview/).

## Notification badges

In the global Workspace Bar settings, set **Notification Badges** to **Dot** or **Text** to show each app's Dock badge at the upper-left of its existing icons. **Text** shows the Dock's count or symbol, using an ellipsis when it cannot fit. Badges are off by default.

The same app-wide badge appears on every matching icon, including expanded scratchpads. Focusing a window does not clear it. Apps without a Dock badge do not show one, and badges do not add otherwise absent app icons.

**Refresh Interval** controls how often badges update, from 1 to 60 seconds (default 5). Turning off badges or the Workspace Bar stops badge checks.

```toml
[workspaceBar]
notificationBadges = "text" # "off", "dot", or "text"
notificationBadgeRefreshIntervalSeconds = 5
```

## Layout and appearance options

Configure position, height, and appearance in Settings:

- **Position** — overlap the menu bar, sit below it, or dock at **Bottom**, **Left**, or **Right**. Available globally and per display.
- **Notch handling** — `Off`, `Move Below Menu Bar`, or a split layout (`Split — Active Left` / `Split — Active Right`) that flows the bar around the notch with your chosen side for the active workspace.
- **Automatically hide and show** — reveal at the bar's edge and hide when the pointer moves inward past the bar and interactions end. See [Automatic hiding](#automatic-hiding).
- **Reveal on modifier hold** — keep the bar hidden until you hold a chosen modifier; with automatic hiding enabled, either trigger can reveal it.
- **Hide empty workspaces** — omit chips for workspaces with no windows.
- **Reserve layout space** — reserve space at the bar's selected edge for tiled and layout-fullscreen windows.
- **Hide in Native Fullscreen** — hide the bar on a monitor while that monitor shows a macOS native fullscreen window, and bring it back on exit; reserved tiled layout space is left untouched so windows do not shuffle around the fullscreen session.
- **Custom accent and text colors**.
- **Per-monitor overrides** — change an individual display's bar independently.

**Unreleased (when building from `main`):** overlapping placement reserves only the space below the menu bar reached by the bar's actual bottom edge, after applying Y offset and constraining it to the display. A bar that fits entirely within the menu-bar area adds no reservation. Below-menu-bar, bottom, left, and right placement continue reserving the configured bar thickness regardless of offsets.

### Bottom and side placement

```toml
[workspaceBar]
position = "bottom" # also "left" or "right"
```

Placement follows the usable display edge, avoiding a visible Dock. X/Y offsets still apply (positive X moves right; positive Y moves upward). **Reserve layout space** reserves the configured bar thickness at the selected edge, including layout-fullscreen windows; offsets do not change that reservation.

Side bars stack upright labels and icons and scroll vertically when needed. **Bar Thickness** (`height` in TOML) controls their width. Drag-and-drop follows the bar's horizontal or vertical order. Stats, hover previews, workspace rename panels, hidden-icon panels, and the fallback OmniWM menu open inward from the displayed bar or icon.

Notch modes, including **Fill Left of Notch**, are ignored at bottom/left/right without changing your saved preference. Existing visibility settings still apply; modifier-hold bars remain overlay-only.

### Automatic hiding

Enable **Automatically hide and show the workspace bar** globally or per display:

```toml
[workspaceBar]
autoHide = true # default: false
```

The bar appears immediately when the pointer touches the edge along its span, not anywhere along the display edge. Once visible, it stays up while the pointer moves along that edge on the same display. It hides when the pointer moves inward beyond the bar's thickness (height for horizontal bars, width for side bars) and interactions end. Menus, popups, previews, renaming, and sheets retain their display's bar; dragging can retain visible bars across displays.

The reveal edge follows the bar's placement and offsets. With no vertical offset, top bars reveal at the screen edge; below-menu-bar placement retains the path across the menu bar to the bar itself. There is no extra activation or retention padding, and no new animations or configurable pointer delays.

Auto-hidden bars never reserve layout space, even while visible. Manual hiding, disabling, and native-fullscreen suppression take precedence. Existing modifier-only configurations remain unchanged; when combined with `autoHide`, touching the edge or holding the modifier can reveal the bar. The existing modifier hold delay applies only to that modifier trigger.

### Additional appearance controls

- **Fill Left of Notch** — an additional notch mode that fills the menu-bar area left of the notch, covering application menus. Without a notch it uses the left half of the menu bar. When effective at a top position, this mode always hides in native fullscreen, regardless of **Hide in Native Fullscreen**.
- **Inactive Icon Opacity** — adjust unfocused app icons from 0–100%; **Reset to System Default** clears the override.
- **Transparent Background** — hide the bar material, tint, and border while keeping its contents interactive.
- **Solid Black Background** — use an opaque black bar; **Transparent Background** takes precedence when both are enabled.
- **Show Item Backgrounds** — show or hide backgrounds behind workspace groups, floating windows, scratchpads, and stats.
- **Show Accent Highlights** — show or hide the focused-workspace outline and focused-icon glow.

These options also support per-monitor overrides. See the [Settings Reference](/config/settings-reference/#workspacebar) for keys and defaults.

## Excluding apps and overriding icons

Exclude individual apps or choose alternate app icons across all monitors in Settings. Icon overrides can also be configured in `settings.toml` (see [Configuration](/config/configuration/)). Quote bundle IDs so TOML treats each dotted identifier as one key:

```toml
[workspaceBar.iconOverrides]
"com.example.App" = "icons/custom.icns"
"com.cmuxterm.app" = "bundle-resource:AppIconDark"
```

`bundle-resource:` loads a named image packaged inside the selected app. The Settings picker discovers likely app-icon resources on demand; runtime-generated or downloaded Dock icons may not be available. Absolute paths are used as written, `~` expands to your home directory, and relative paths are resolved from the directory containing `settings.toml`.

:::note
Overrides affect only the workspace bar. A valid override takes precedence over the app's standard icon; an unavailable or invalid image falls back to the standard icon, then the dashed placeholder when no app icon is available. OmniWM does not watch image files; use Replace to reload a file changed in place.
:::
