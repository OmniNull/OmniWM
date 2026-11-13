---
title: Scratchpads
description: Ten slots of floating windows you can summon over any workspace and park off-screen again.
sidebar:
  order: 6
---

A scratchpad is a slot that holds any number of floating windows and overlays them on the workspace you are looking at. There are ten slots, numbered 1 to 10; a slot with no windows in it is inert and invisible.

## Assigning and toggling

Both hotkey families start unassigned — bind them in Settings under Keyboard Shortcuts (see [keyboard shortcuts](/guides/keyboard-shortcuts/)):

- **Toggle Scratchpad N Assignment for Focused Window** moves the focused window into slot N, floating it if it was tiled. The window stays visible when slot N is already revealed; otherwise it is parked off-screen. Pressing the same shortcut again on a window already in slot N returns it to the layout.
- **Toggle Scratchpad N** reveals eligible windows in slot N on the monitor you are interacting with, or parks them again if they are already there. Revealing a slot parks whichever slot was showing, so at most one scratchpad is on screen at a time.

Hotkey and CLI toggles leave macOS-hidden apps hidden and skip windows suspended in native fullscreen. To reveal a hidden app from a scratchpad, click its workspace-bar pill while the slot is hidden; that activation path can unhide the app. Exit native fullscreen before revealing a suspended window.

A revealed scratchpad follows you across workspace switches and stays up until you toggle it off. If it is showing on another monitor, its shortcut summons it to the one you are on. Parked windows slide off the screen edge, leaving a 1-pixel sliver on-screen.

Revealed windows are ordinary floating windows: whether clicking something underneath pushes them behind it is governed by the usual focus and raise behaviour, including **Raise Window When Focus Follows Mouse**.

## Joining by App Rule

**Unreleased — available when building from `main`.** An [App Rule](/features/app-rules/#rule-destination) with a **Scratchpad** destination adds each matching window to that slot when OmniWM starts managing it. The rule names the slot by number, not by label:

```toml
[[appRules]]
bundleId = "com.apple.TextEdit"
scratchpad = 1
```

- **Hidden slot:** the new window is parked and the slot stays hidden. Focus stays on, or returns to, the window you were using when it's still on screen; otherwise OmniWM focuses another window, if there is one. The new window can show on screen for a moment before it's parked. If the new window is focused when it arrives, OmniWM reveals the slot instead, as if you clicked the window's icon in the slot's pill, and the window is never parked.
- **Revealed slot:** the new window appears in place, on the workspace OmniWM would normally put it on, without being moved.
- **Startup:** no slot is revealed, so matching windows that are already open go back into their slots, parked.
- **Taking a window out:** a window you take out of a slot stays out, even when its title changes. The rule applies again only to windows the app opens later.

A revealed slot is hidden again once its last window is gone, whether the window closed, its app quit, or you released, moved or tiled it. The next window to join it arrives as described under **Hidden slot**.

:::caution
Remove any script that calls `omniwmctl command scratchpad assign` or `omniwmctl window assign-to-scratchpad` on `windows-changed` events. Assigning is a toggle, so it would take a window the rule just added back out of its slot.
:::

## Workspace-bar pills and labels

Each non-empty slot gets a pill in the [workspace bar](/features/workspace-bar/) showing its name and its windows' icons; clicking the pill toggles that scratchpad. Slots are identified by number everywhere, and an optional label replaces the number in the workspace bar and in `omniwmctl` output. Labels live in `settings.toml` (see [Configuration](/config/configuration/)):

```toml
[scratchpads.labels]
1 = "term"
3 = "COMMS"
```

## CLI

Scratchpads are scriptable through the [CLI](/reference/cli/overview/):

```sh
omniwmctl command scratchpad assign 3
omniwmctl command scratchpad toggle 3
omniwmctl query windows --scratchpad
```

`scratchpad assign` and `scratchpad toggle` take a slot number from 1 to 10; the `--scratchpad` flag limits the window query to windows assigned to a scratchpad.

:::note
Scratchpad membership lasts for the lifetime of the OmniWM process; only the labels are persisted. **Unreleased:** available when building from `main`. App Rules with a scratchpad destination put matching windows back in their slots at startup.
:::
