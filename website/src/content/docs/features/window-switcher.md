---
title: Window Switcher
description: Switch individual windows with thumbnail previews across all workspaces, the workspaces shown on each monitor, or just the active workspace.
sidebar:
  order: 8
---

Enable **Settings → Window Switcher → Enable Window Switcher** to cycle through windows with thumbnail previews. The feature is off by default. Disable matching shortcuts in AltTab before enabling it.

## Shortcuts and workspace scope

Configure **Command-Tab** and **Option-Tab** independently as **Active Workspace**, **Visible Workspaces**, **All Workspaces**, **Last Used Scope**, or **Disabled**. New configurations assign Command-Tab to the active workspace and Option-Tab to all workspaces. Disabling Command-Tab leaves the macOS application switcher available.

- Hold the shortcut's Command or Option key and press `Tab` to cycle through windows. `Shift + Tab` reverses direction. Left and right move between cards; up and down move between rows.
- Release the modifier or press `Return` to focus the selected window. Click a thumbnail to select it directly.
- Press `Escape` or click outside to cancel.
- Press `S` or click the scope button to move to the next scope: Active Workspace, then Visible Workspaces, then All Workspaces. Visible Workspaces is skipped when only one workspace is shown, because it would list the same windows as Active Workspace.
- Press `W` or use the close button that appears when hovering over a preview to close that window. The card stays until the app actually closes the window, including when it asks about unsaved changes.

**Active Workspace** uses the workspace on OmniWM's interaction monitor when the switcher opens. **Visible Workspaces** (**Unreleased — available when building from `main`**) uses the workspace shown on each connected monitor when the switcher opens and leaves out workspaces that no monitor is showing; the switcher itself still opens on the interaction monitor. **All Workspaces** includes tracked windows across monitors, including floating windows and hidden applications. Minimized windows remain selectable with dimmed previews; selecting one restores it. Natively withdrawn and untracked windows are omitted.

Each shortcut opens its assigned scope. **Last Used Scope** remembers the choice made with S or the scope button. For a single shortcut with a remembered scope, set Command-Tab to Last Used Scope and Option-Tab to Disabled.

The first forward Tab selects the most recently focused window available in that scope, excluding the current window. Further presses follow the selected window order. Repeatedly pressing and releasing the shortcut switches back and forth between the two most recently used windows. Shift-Tab starts in reverse display order.

A scope with one or two windows uses the same preview panel and controls as a larger scope. Opening the switcher does not activate a window: release the shortcut's modifier, press Return, or click a card to select it. Escape cancels, and S still changes the workspace scope.

## From the command line

**Unreleased — available when building from `main`.** `omniwmctl command window-switcher next` and `omniwmctl command window-switcher previous` let an external hotkey manager, such as skhd, Hammerspoon or Karabiner-Elements, drive the switcher. Only **Enable Window Switcher** has to be on. Command-Tab and Option-Tab can both be set to **Disabled**, and `hotkeysEnabled` can be `false`.

```sh
# ~/.skhdrc
alt - tab         : omniwmctl command window-switcher next
alt + shift - tab : omniwmctl command window-switcher previous
```

- When the command runs, OmniWM checks which of Command, Option and Control are held. It keeps the switcher open until one of them is released, then focuses the selected window. This also works with Control and Hyper chords.
- While it is open, more `next` or `previous` calls move the selection in the same session. `Tab`, the arrow keys, `Return`, `Escape`, `S` and `W` work as they do with the built-in shortcut. Other keys pass through, so the hotkey manager still receives its own chord.
- If no modifier is held, as in a script, or the key is released before the command arrives, the command switches once and leaves no panel open.
- An optional third word sets the scope for that opening: `active-workspace`, `visible-workspaces` or `all-workspaces`. Without it, the switcher uses the remembered scope. While it is open, the scope word is ignored.

Watching for the modifier release uses OmniWM's input event tap, which needs Input Monitoring permission. Without it, the command switches once.

## Appearance and previews

**Window Order** offers two choices:

- **Omni Layout** (default): windows follow Niri column and tile order or Dwindle tree order within each workspace, with floating windows afterward. Visible Workspaces and All Workspaces group them in workspace-bar order.
- **Last Used**: windows appear from most recently focused to least recently focused across the selected scope. Windows without focus history follow afterward in Omni layout order.

Visible Workspaces and All Workspaces show a workspace badge using the same name or emoji as the bar.

**Show Switcher Footer** controls the scope button and window count together. Turning it off removes the footer; S still changes scope.

Previews fill each card and stay sharp. A short, subtle fade behind the bottom caption and a text shadow improve readability. Absolute paths are shortened to their final component; hovering over the card shows the full original title.

Cards wrap into additional rows at maximum width. When the grid exceeds the available screen height, scroll vertically with a mouse or trackpad. Keyboard navigation brings the selected card into view. Only visible, non-minimized cards request previews. Capture streams stop when the switcher closes, while a bounded thumbnail cache remains available for the next opening. Cached previews appear immediately and stay the same for the rest of that opening; the cache refreshes for the next opening. Minimized windows keep their last captured preview, or show a Minimized label if none is available.

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
order = "omniLayout"
scope = "allWorkspaces"
```

`commandTab` and `optionTab` accept `"activeWorkspace"`, `"visibleWorkspaces"`, `"allWorkspaces"`, `"remembered"`, or `"disabled"`. `scope` stores the last chosen workspace scope: `"activeWorkspace"`, `"visibleWorkspaces"`, or `"allWorkspaces"`. Changing shortcut assignments cancels an open switcher.

`order` accepts `"omniLayout"` or `"lastUsed"`. Existing configurations keep Omni layout ordering.

Enabled shortcuts use OmniWM's existing input event tap and require Input Monitoring permission. Close Overview or the command palette before opening the switcher.
