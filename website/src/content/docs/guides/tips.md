---
title: Tips
description: Mouse, trackpad, and workspace tricks that make OmniWM faster to drive.
sidebar:
  order: 6
---

## Name your workspaces

Create named workspaces in Settings to organize by project or context — emojis work too 🥳.

## Tame problem apps with rules

Use [App Rules](/features/app-rules/) to exclude problematic apps from tiling or assign them to specific workspaces.

## Swap windows by dragging

Drag a tiled window by its title bar to rearrange it or move it onto another display. Native title-bar movement is always available. In [Overview](/features/overview/), drag a thumbnail to a workspace, window position or Niri column gap.

Niri rearranges columns and windows while you drag. Dwindle swaps tiles at their centers and inserts beside tiles, between splits or at workspace edges. Dwindle tab groups move together; dragging an individual group tab moves only that tab.

Moves work between Niri and Dwindle in any combination. **Dwindle Group Across Displays** in **Settings → Mouse & Trackpad** chooses whether a title-bar drag carries the whole group or only the active window. A whole group moved into Niri becomes a tabbed column. A swap that would not fit the destination is refused, and a drop on a fullscreen space cancels.

The **Move Window** trackpad gesture moves the actual window with your fingers. It stays on the starting display, and where you release decides what happens. The middle of another window swaps the two. A part near one of its edges places the window on that side. Niri moves the window under the pointer. On a horizontal strip, top or bottom stacks it with the target, and left or right gives it a new column. On a vertical strip those pairs trade places. Dwindle moves the tile under the pointer, including its group, and places it beside the target tile; the edge of the tiled area and the line between two tiles are targets too. Releasing away from a target or cancelling the gesture restores the original position, and Undo takes a drop back.

## Resize a window

Drag a tiled window's edge or corner to resize it. Niri and Dwindle adjust the layout while you drag, and the change finishes when you release. Hold `Option` during an edge drag to resize around the center. Trackpad and keyboard resizing also update the real windows directly.

## Scroll the strip with a mouse wheel

Hold `Option + Shift + Mouse Scroll Wheel` (default, configurable) to scroll along the active Niri primary axis: left/right in horizontal orientation or up/down in vertical orientation.

If a smooth mouse wheel needs too much movement to switch columns, expand **Scroll columns** under **Settings → Mouse & Trackpad → Trackpad** and increase **Mouse wheel sensitivity**. The default `1.0x` preserves existing behavior. Higher values speed up window navigation without changing normal scrolling in apps or trackpad sensitivity. The same setting is available as `mouseWheelSensitivity` in the TOML `[gestures]` table.

## Trackpad gestures

Use three or four fingers (configurable) to scroll along the active Niri primary axis; direction can be inverted. Workspace switching and window move/resize also support two fingers, but column scrolling does not.

A contact that macOS labels as a palm or the side of a hand, or one much larger than a fingertip, does not count toward a gesture's finger count. A palm resting on the trackpad therefore neither turns a two-finger scroll into a three-finger gesture nor stops a three-finger swipe made beside it.

The **Trackpad scroll style** picker under **Settings → Mouse & Trackpad → Trackpad Gestures → Scroll columns** chooses how the strip responds:

- **Snap to Columns** (default) — the scroll snaps to the nearest column.
- **Momentum** — free inertial scrolling with rubber-band edges.

All five gesture assignments appear together in **Trackpad Gestures**. You can select fingers while a gesture is off. If an assignment conflicts, **Set Up…** shows exactly which gestures would turn off and lets you choose before applying. Turning off **Scroll columns** also turns off modifier + mouse-wheel column scrolling.

## Move and resize with the trackpad (opt-in)

Enable **Move windows** or **Resize windows** in **Settings → Mouse & Trackpad → Trackpad Gestures** to drag without clicking. The gesture targets the tiled window under the cursor in either layout; lift all fingers to finish. Move drops onto the window under the drop position (its middle swaps, a part near an edge places the window on that side) and stays on the starting monitor. Resize adjusts the nearest movable edges. The pointer itself stays in place.

Choose two, three, or four fingers for each action. Defaults are four fingers to move and three to resize, with both actions disabled. Column scrolling is on by default with three fingers, so the Resize row first offers **Set Up…**; pick another finger count (two fingers can intercept normal scrolling in apps) or turn off **Scroll columns**. A window gesture needs a finger count unused by other enabled OmniWM gestures, including column scrolling, workspace switching, and Overview. **Set Up…** previews which conflicting gestures would turn off and lets you choose before applying the assignment. You can also reassign or disable those gestures yourself. At **1.0x** sensitivity, a full trackpad sweep travels across the starting screen.

Turn off matching macOS gestures in **System Settings → Trackpad → More Gestures** to prevent Mission Control, App Exposé, or full-screen app switching from firing alongside window gestures.

## Workspace swipe (opt-in)

Opt in under **Settings → Mouse & Trackpad**: swipe with a configurable finger count (2/3/4) and axis (horizontal/vertical) to switch to the next/previous workspace on the monitor under the cursor, one switch per swipe. When sharing fingers with enabled column scrolling in Niri, workspace swipes use the perpendicular axis on each display: vertical for horizontal Niri containers, horizontal for vertical containers. Otherwise, they use the selected axis.

:::caution[Mission Control can intercept vertical swipes]
For vertical swipes with three or four fingers, first turn off Mission Control in System Settings → Trackpad → More Gestures so macOS does not intercept the gesture.
:::
