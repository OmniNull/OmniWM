---
title: Overview Mode
description: See every window on every workspace at once as live, searchable thumbnails.
sidebar:
  order: 3
---

Press `Option + Shift + O` and all of your workspaces' windows fly into a scrollable overview of thumbnails. Empty workspaces remain visible by default. The workspace bar's **Hide empty workspaces** setting also applies to Overview on that display; when enabled, it hides inactive empty workspaces and keeps the active workspace visible. Configure the 50–150% zoom, scrolling controls, and backdrop and window-border colors in **Settings → Overview**.

Turn Overview off in Settings. Its shortcut, mouse button, gesture, and commands then stop opening it; saved input assignments return when it is re-enabled.

## Finding and focusing windows

- Type to filter by window title or app name, including inactive members of Niri tabbed columns and Dwindle groups; `Backspace` deletes search text.
- Grouped windows share one preview card. Use its arrows or click the position indicator to choose a window by title. Small Dwindle cards use a compact count picker. Browsing changes the preview; the chosen window becomes active when you dismiss Overview to it.
- `Arrow Keys` navigate spatially; `Left` / `Right` stay within the current workspace. `Tab` / `Shift + Tab` cycle forward or backward through matching windows, and keyboard navigation automatically scrolls the selected thumbnail into view.
- `Enter` focuses the selected window; pressing and releasing a thumbnail without dragging it focuses that window. `Escape`, the configured Overview shortcut, and clicking the backdrop also dismiss Overview and focus the current selection; `Escape` does not clear search first.
- Mouse and trackpad scrolling follow the system Natural Scrolling setting. **Invert Scrolling Direction** under **Settings → Overview → Input** reverses it for both; **Mouse Wheel Speed** changes wheel scrolling without changing trackpad speed.
- `Alt (Option) + Shift + Mouse Scroll` changes the zoom. Closing Overview saves that zoom for the next opening.
- If another application takes focus, Overview dismisses without stealing focus back.
- With the Overview gesture enabled in **Settings → Mouse & Trackpad**, a three- or four-finger swipe up tracks your fingers like Mission Control: release past halfway or flick to open, release early to cancel, and swipe down to close. With OmniWM animations disabled or macOS Reduce Motion enabled, swipes open and close Overview without the finger-tracked transition.

## Managing windows from Overview

- `Command + W` closes the selected window once per press and keeps Overview open; selection advances only after the window has closed.
- Drag a thumbnail onto a workspace, an exact window position, or a Niri column gap; no modifier is needed, and layouts without an exact placement equivalent fall back to moving the window to the destination workspace.
- Your assigned structural move, reorder, consume/expel, and workspace-transfer [shortcuts](/guides/keyboard-shortcuts/) operate on the selected thumbnail while Overview is open. In Niri workspaces you can reorder windows and columns, consume or expel windows, move windows into or out of columns, move windows across workspaces and monitors, and move whole columns between Niri workspaces. In Dwindle workspaces, Overview supports moving windows across workspaces and closing them.
- A successful move keeps the moved window selected and activates its destination workspace and monitor behind Overview.

:::note
Thumbnails require the optional Screen Recording permission. Without it, Overview still works — the cards simply render without window pictures.
:::
