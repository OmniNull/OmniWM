---
title: Workspace Bar
description: A per-display bar that shows your workspaces and their windows at a glance.
sidebar:
  order: 4
---

The workspace bar runs along the selected edge of each display, as a floating island or, with **Full Width**, across the whole edge. It shows a chip per workspace — with the workspace's name, emoji-friendly — and the icons of the apps open there.

The bar is drawn by [OmniShell](/omnishell/configuration/bars-drawers/) widgets that you can restyle or replace.

Window hover previews can be turned off separately. Turning off the global Workspace Bar hides it on every monitor, while saved monitor overrides take effect again when it is re-enabled.

## Settings

Open **Settings > Styles & Widgets > Bar** to arrange widgets, select a widget for its options, and adjust placement, appearance and behavior. Use **Display** for display-specific settings. The enable switches, exclusions and icon overrides apply to every style. Select a style in the strip to edit it; choose **Use Style** to activate it. The bar’s controls remain editable while its enable switch is off.

## Clicking the bar

- Click a workspace chip to switch to that workspace.
- Click an app icon to focus that window directly.
- When **Deduplicate App Icons** is enabled, multiple windows from one app share a single grouped icon with a count badge; click a grouped icon to open their window list, while a single-window icon focuses that window directly.
- macOS-hidden windows are marked with an eye-slash badge; selecting a hidden window unhides its app and focuses that exact window.
- Non-empty [scratchpad](/features/scratchpads/) slots appear as pills; clicking a pill toggles that scratchpad.

## System Stats

Optionally show a System Stats button that opens a CPU, memory, GPU, disk, and uptime popup. The `Toggle System Stats` hotkey and `omniwmctl command toggle-system-stats` drive the same popup, and both do nothing unless a monitor currently shows that workspace-bar button. See the [CLI reference](/reference/cli/overview/). The button is the shell's `system-stats` widget, so it must stay in one of the bar's groups (`trailing` by default).

## Notifications

**Unreleased: available when building from `main`.** The `notifications` widget shows retained macOS notifications. If your style does not already show it, use **Settings > Styles & Widgets > Bar > Add Widget…** to add **Notifications**. This is separate from the Dock badges described below.

Grant OmniWM **Full Disk Access** in **System Settings > Privacy & Security**, then quit and reopen it. The widget's **Settings** button opens that pane. The feed reads Notification Center's database when it changes; native persistence can delay updates by several seconds. Storage errors and incomplete snapshots appear in the widget. **Details** shows participants, attachments, action definitions and native metadata.

Use a notification's close button to request dismissal, or **Clear All** to process the retained snapshot. **Cancel** stops Clear All after the current action; it cannot undo requests already dispatched. A **Reply** control appears only when the notification declares one uniquely identifiable text-input action with send-button metadata. Replies and dismissal require **Accessibility** and matching controls in Notification Center. Unsupported or ambiguous actions report their outcome; macOS may keep some notifications.

“Reply submitted to Notification Center” confirms dispatch of the native action, not delivery to the recipient. If Notification Center remains open after an action, the widget asks you to close it. Custom widgets can use the same [notification data and commands](/omnishell/reference/context-data/#notification-snapshots).

## Notification badges

With **All Displays** selected, set **Notification Badges** under **Workspace Bar Behavior** to **Dot** or **Text** to show each app's Dock badge at the upper-left of its existing icons. **Text** shows the Dock's count or symbol, using an ellipsis when it cannot fit. Badges are off by default.

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
- **Full Width** — span the whole edge, with the shell's `leading`, `center` and `trailing` widgets at its start, middle and end. With **Position → Below Menu Bar**, it leaves macOS's menu-bar auto-hide preference unchanged (**Unreleased:** available when building from `main`). At other positions, including bottom and side placements, an enabled full-width bar sets macOS's **Automatically hide and show the menu bar** to Always, including while automatic hiding, Reveal on modifier hold or native fullscreen hides the bar. When the last bar requesting automatic hiding moves to **Below Menu Bar**, is disabled or hidden with Toggle Workspace Bar, or OmniWM quits normally, your previous choice returns if the macOS setting still matches the value OmniWM applied. Otherwise, OmniWM keeps your new choice. A full-width bar at another position on another display can still request automatic hiding, because this is a system-wide setting. A crash can leave automatic hiding active; relaunch OmniWM and move its full-width bars below the menu bar, disable them, or quit normally to restore the saved preference.
- **Notch handling** — `Off`, `Move Below Menu Bar`, `Right of Notch`, or a split layout (`Split — Active Left` / `Split — Active Right`) that flows the bar around the notch with your chosen side for the active workspace. `Right of Notch` centers the bar without a notch, or places it 8 points to the right of the notch; offsets still apply.
- **Automatically hide and show** — reveal at the bar's edge and hide when the pointer moves inward past the bar and interactions end. See [Automatic hiding](#automatic-hiding).
- **Reveal on modifier hold** — keep the bar hidden until you hold a chosen modifier; with automatic hiding enabled, either trigger can reveal it.
- **Hide empty workspaces** — omit chips for workspaces with no windows.
- **Reserve layout space** — reserve space at the bar's selected edge for tiled and layout-fullscreen windows.
- **Hide in Native Fullscreen** — hide the bar on a monitor while that monitor shows a macOS native fullscreen window, and bring it back on exit; reserved tiled layout space is left untouched so windows do not shuffle around the fullscreen session.
- **Custom accent and text colors**.
- **Per-monitor overrides** — change an individual display's bar independently.

Overlapping placement reserves only the space below the menu bar reached by the bar's actual bottom edge, after applying Y offset and constraining it to the display. A bar that fits entirely within the menu-bar area adds no reservation. Below-menu-bar, bottom, left, and right placement continue reserving the configured bar thickness regardless of offsets.

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
autoHideRevealDelayMilliseconds = 0 # 0-1000
autoHideHideDelayMilliseconds = 0 # 0-1000
```

The bar appears when the pointer touches the edge along its span, not anywhere along the display edge. Once visible, it stays up while the pointer moves along that edge on the same display. It hides when the pointer moves inward beyond the bar's thickness (height for horizontal bars, width for side bars) and interactions end. Menus, popups, previews, renaming, and sheets retain their display's bar; dragging can retain visible bars across displays.

The reveal edge follows the bar's placement and offsets. With no vertical offset, top bars reveal at the screen edge; below-menu-bar placement retains the path across the menu bar to the bar itself. There is no extra activation or retention padding and no animation.

**Auto-Hide Reveal Delay** is how long the pointer must stay at the edge before the bar appears; leaving the edge sooner cancels the reveal. **Auto-Hide Hide Delay** is how long the bar stays after the pointer moves inward past it and interactions end; returning to the bar sooner cancels the hide. Both default to 0 ms, apply to every display that auto-hides, and accept up to 1000 ms.

Auto-hidden bars never reserve layout space, even while visible. Manual hiding, disabling, and native-fullscreen suppression take precedence. Existing modifier-only configurations remain unchanged; when combined with `autoHide`, touching the edge or holding the modifier can reveal the bar. The modifier hold delay applies only to the modifier trigger, and the auto-hide delays only to the pointer.

### Additional appearance controls

- **Fill Left of Notch** — an additional notch mode that fills the menu-bar area left of the notch, covering application menus. Without a notch it uses the left half of the menu bar. When effective at a top position, this mode always hides in native fullscreen, regardless of **Hide in Native Fullscreen**.
- **Inactive Icon Opacity** — adjust unfocused app icons from 0–100%; **Reset to Style Defaults** clears the override.
- **Transparent Background** — hide the bar material, tint, and border while keeping its contents interactive.
- **Solid Black Background** — use an opaque black bar; it takes precedence over **Transparent Background** when both are enabled.
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
