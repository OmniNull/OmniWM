---
title: Window Switcher
description: Switch individual windows with thumbnail previews across all workspaces or just the active workspace.
sidebar:
  order: 8
---

Enable **Settings → Window Switcher → Enable Window Switcher** to cycle through windows with thumbnail previews. The feature is off by default. Disable matching shortcuts in AltTab before enabling it.

## Shortcuts and workspace scope

Configure **Command-Tab** and **Option-Tab** independently as **Active Workspace**, **All Workspaces**, **Last Used Scope**, or **Disabled**. New configurations assign Command-Tab to the active workspace and Option-Tab to all workspaces. Disabling Command-Tab leaves the macOS application switcher available.

- Hold the shortcut's Command or Option key and press `Tab` to cycle through windows in recency order. `Shift + Tab` reverses direction; arrow keys also cycle.
- Release the modifier or press `Return` to focus the selected window. Click a thumbnail to select it directly.
- Press `Escape` or click outside to cancel.
- Press `W` or click the scope button to switch between all workspaces and the active workspace.

**Active Workspace** uses the workspace on OmniWM's interaction monitor when the switcher opens. **All Workspaces** includes tracked windows across monitors, including floating windows and hidden applications. Minimized, natively withdrawn, and untracked windows are omitted.

Each shortcut opens its assigned scope. **Last Used Scope** remembers the choice made with W or the scope button. For a single shortcut with a remembered scope, set Command-Tab to Last Used Scope and Option-Tab to Disabled.

## Appearance and previews

**Show Switcher Footer** controls the scope button and window count together. Turning it off removes the footer; W still changes scope.

The panel displays a row around the current selection. Continue cycling to reach windows beyond the visible row. Previews are captured on demand and released when the switcher closes.

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
