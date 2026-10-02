---
title: Window Switcher
description: Switch individual windows with thumbnail previews across all workspaces or just the active workspace.
sidebar:
  order: 8
---

Enable **Settings → Window Switcher → Enable Window Switcher** to cycle through windows with thumbnail previews. The feature is off by default. Disable matching shortcuts in AltTab before enabling it.

## Shortcuts and workspace scope

Configure **Command-Tab** and **Option-Tab** independently as **Active Workspace**, **All Workspaces**, **Last Used Scope**, or **Disabled**. New configurations assign Command-Tab to the active workspace and Option-Tab to all workspaces. Disabling Command-Tab leaves the macOS application switcher available.

- Hold the shortcut's Command or Option key and press `Tab` to cycle through windows. `Shift + Tab` reverses direction. Left and right move between cards; up and down move between rows.
- Release the modifier or press `Return` to focus the selected window. Click a thumbnail to select it directly.
- Press `Escape` or click outside to cancel.
- Press `S` or click the scope button to switch between all workspaces and the active workspace.
- Press `W` or use the close button that appears when hovering over a preview to close that window. The card stays until the app actually closes the window, including when it asks about unsaved changes.

**Active Workspace** uses the workspace on OmniWM's interaction monitor when the switcher opens. **All Workspaces** includes tracked windows across monitors, including floating windows and hidden applications. Minimized, natively withdrawn, and untracked windows are omitted.

Each shortcut opens its assigned scope. **Last Used Scope** remembers the choice made with S or the scope button. For a single shortcut with a remembered scope, set Command-Tab to Last Used Scope and Option-Tab to Disabled.

## Appearance and previews

Windows follow their layout order within each workspace: Niri column and tile order, or Dwindle tree order, with floating windows afterward. All Workspaces groups them in workspace-bar order and shows a workspace badge using the same name or emoji as the bar. Active Workspace uses the same layout ordering for its windows.

**Show Switcher Footer** controls the scope button and window count together. Turning it off removes the footer; S still changes scope.

Previews fill each card and stay sharp. A short, subtle fade behind the bottom caption and a text shadow improve readability. Absolute paths are shortened to their final component; hovering over the card shows the full original title.

Cards wrap into additional rows at maximum width. When the grid exceeds the available screen height, scroll vertically with a mouse or trackpad. Keyboard navigation brings the selected card into view. Only visible cards request previews, and capture resources are released when the switcher closes.

:::note
Thumbnails require Screen Recording permission. Without it, window titles and keyboard selection remain available. Some offscreen or native fullscreen windows may show an unavailable-preview label.
:::

## Configuration

```toml
[windowSwitcher]
enabled = true
commandTab = "activeWorkspace"
optionTab = "allWorkspaces"
showFooter = true
scope = "allWorkspaces"
```

`commandTab` and `optionTab` accept `"activeWorkspace"`, `"allWorkspaces"`, `"remembered"`, or `"disabled"`. `scope` stores the last chosen workspace scope. Changing shortcut assignments cancels an open switcher.

Enabled shortcuts use OmniWM's existing input event tap and require Input Monitoring permission. Close Overview or the command palette before opening the switcher.
