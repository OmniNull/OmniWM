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

Hold the configured mouse-move modifier and left-drag a tiled window to rearrange it. In Niri, dropping onto another window swaps them; add `Shift` before starting the drag to insert into a column instead. Dwindle moves an entire tab group together. The modifier defaults to `Option` and can be changed or disabled in **Settings → Mouse & Trackpad**. In [Overview](/features/overview/), dragging a thumbnail needs no modifier and targets a workspace, window position, or Niri column gap.

**Unreleased:** When building from `main`, Dwindle chooses the action from the drop position. Drop within the central 40% of a target tile's width and height to swap; the preview covers the whole tile. Drop toward its top, bottom, left, or right to insert on that side; the preview covers the corresponding half. `Shift` is not required and does not change Dwindle's drop action. Move into a narrow band (up to 24 points wide) along an edge of the workspace's working area to insert at that outer edge instead. Edge targets take precedence once the pointer has moved at least 10 points from the drag start. The preview then spans half the working area, and the remaining layout stays together on the other side with its internal split ratios preserved. The working area respects outer gaps, reserved workspace-bar space, the menu bar, and the Dock; dropping outside it cancels the move.

Tile and workspace-edge insertions aim for an equal split where window minimum sizes allow. Tab groups move together, within the same workspace. Away from a workspace edge, dropping over the source tile or outside another tile cancels the move. An outer-edge insertion requires another visible tile and is unavailable while a visible tile is fullscreen. The action and preview follow the pointer during the drag, and the final release position determines the result. Insertion between existing splits is not supported. Multi-finger window-move gestures keep their existing swap behavior.

## Resize with a right-drag

Hold the configured right-mouse resize modifier (`Option` by default) and right-drag a tiled window to resize it in either layout.

## Scroll the strip with a mouse wheel

Hold `Option + Shift + Mouse Scroll Wheel` (default, configurable) to scroll along the active Niri primary axis: left/right in horizontal orientation or up/down in vertical orientation.

## Trackpad gestures

Use 2/3/4-finger gestures (configurable) along the active Niri primary axis; direction can be inverted.

The **Trackpad scroll style** picker under **Settings → Mouse & Trackpad → Trackpad Gestures → Scroll columns** chooses how the strip responds:

- **Snap to Columns** (default) — the scroll snaps to the nearest column.
- **Momentum** — free inertial scrolling with rubber-band edges.

All five gesture assignments appear together in **Trackpad Gestures**. You can select fingers while a gesture is off. If an assignment conflicts, **Set Up…** shows exactly which gestures would turn off and lets you choose before applying. Turning off **Scroll columns** also turns off modifier + mouse-wheel column scrolling.

## Move and resize with the trackpad (opt-in)

Enable **Move windows** or **Resize windows** in **Settings → Mouse & Trackpad → Trackpad Gestures** to drag without clicking. The gesture targets the tiled window under the cursor in either layout; lift all fingers to finish. Move swaps with the window under the drop position and stays on the starting monitor. Resize adjusts the nearest movable edges. The pointer itself stays in place.

Choose two, three, or four fingers for each action. Defaults are four fingers to move and three to resize, with both actions disabled. Column scrolling is on by default with three fingers, so the Resize row first offers **Set Up…**; pick another finger count (two fingers can intercept normal scrolling in apps) or turn off **Scroll columns**. A window gesture needs a finger count unused by other enabled OmniWM gestures, including column scrolling, workspace switching, and Overview. **Set Up…** previews which conflicting gestures would turn off and lets you choose before applying the assignment. You can also reassign or disable those gestures yourself. At **1.0x** sensitivity, a full trackpad sweep travels across the starting screen.

Turn off matching macOS gestures in **System Settings → Trackpad → More Gestures** to prevent Mission Control, App Exposé, or full-screen app switching from firing alongside window gestures.

## Workspace swipe (opt-in)

Opt in under **Settings → Mouse & Trackpad**: swipe with a configurable finger count (2/3/4) and axis (horizontal/vertical) to switch to the next/previous workspace on the monitor under the cursor, one switch per swipe. When sharing fingers with enabled column scrolling in Niri, workspace swipes use the perpendicular axis on each display: vertical for horizontal Niri containers, horizontal for vertical containers. Otherwise, they use the selected axis.

:::caution[Mission Control can intercept vertical swipes]
For vertical swipes with three or four fingers, first turn off Mission Control in System Settings → Trackpad → More Gestures so macOS does not intercept the gesture.
:::
