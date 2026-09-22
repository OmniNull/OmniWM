---
title: Workspace Bar
description: A floating per-display island that shows your workspaces and their windows at a glance.
sidebar:
  order: 4
---

The workspace bar is a floating island centered along the selected edge of each display. It shows a chip per workspace — with the workspace's name, emoji-friendly — and the icons of the apps open there.

## Clicking the bar

- Click a workspace chip to switch to that workspace.
- Click an app icon to focus that window directly.
- When **Deduplicate App Icons** is enabled, multiple windows from one app share a single grouped icon with a count badge; click a grouped icon to open their window list, while a single-window icon focuses that window directly.
- macOS-hidden windows are marked with an eye-slash badge; selecting a hidden window unhides its app and focuses that exact window.
- Non-empty [scratchpad](/features/scratchpads/) slots appear as pills; clicking a pill toggles that scratchpad.

## System Stats

Optionally show a System Stats button that opens a CPU, memory, GPU, disk, and uptime popup. The `Toggle System Stats` hotkey and `omniwmctl command toggle-system-stats` drive the same popup, and both do nothing unless a monitor currently shows that workspace-bar button. See the [CLI reference](/reference/cli/overview/).

## Layout and appearance options

Configure position, height, and appearance in Settings:

- **Position** — overlap the menu bar, sit below it, or dock at **Bottom**, **Left**, or **Right**. Available globally and per display.
- **Notch handling** — `Off`, `Move Below Menu Bar`, or a split layout (`Split — Active Left` / `Split — Active Right`) that flows the bar around the notch with your chosen side for the active workspace.
- **Reveal on modifier hold** — keep the bar hidden until you hold a chosen modifier.
- **Hide empty workspaces** — omit chips for workspaces with no windows.
- **Reserve layout space** — reserve room for the bar so tiled windows never sit underneath it.
- **Hide in Native Fullscreen** — hide the bar on a monitor while that monitor shows a macOS native fullscreen window, and bring it back on exit; reserved tiled layout space is left untouched so windows do not shuffle around the fullscreen session.
- **Custom accent and text colors**.
- **Per-monitor overrides** — change an individual display's bar independently.

### Bottom and side placement

```toml
[workspaceBar]
position = "bottom" # also "left" or "right"
```

Placement follows the usable display edge, avoiding a visible Dock. X/Y offsets still apply (positive X moves right; positive Y moves upward). **Reserve layout space** reserves the configured bar thickness at the selected edge, including layout-fullscreen windows; offsets do not change that reservation.

Side bars stack upright labels and icons and scroll vertically when needed. **Bar Thickness** (`height` in TOML) controls their width. Stats, hidden-icon panels, and the fallback OmniWM menu open inward from the displayed bar or icon.

Notch modes, including **Fill Left of Notch**, are ignored at bottom/left/right without changing your saved preference. Per-display overrides accept the same positions. Existing visibility toggles, modifier-hold reveal, and **Hide in Native Fullscreen** still apply; modifier-hold bars remain overlay-only.

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
