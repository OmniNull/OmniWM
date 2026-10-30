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

Hold the configured mouse-move modifier and left-drag a tiled window to rearrange it. Dwindle moves an entire tab group together. The modifier defaults to `Option` and can be changed or disabled in **Settings → Mouse & Trackpad**. In [Overview](/features/overview/), dragging a thumbnail needs no modifier and targets a workspace, window position, or Niri column gap.

Niri and Dwindle choose the action from the drop position. Drop within the central 40% of a target tile's width and height to swap; the preview covers the whole tile. Drop toward its top, bottom, left, or right to insert on that side; the preview covers the corresponding half. `Shift` is not required and does not change the drop action. In Niri, the two edges that face neighboring columns (left and right on a horizontal strip, top and bottom on a vertical one) open a new column of the default width on that side, and the other two edges stack the window into the target's column. In Dwindle, move into a narrow band (up to 24 points wide) along an edge of the workspace's working area to insert at that outer edge instead. Edge targets take precedence once the pointer has moved at least 10 points from the drag start. The preview then spans half the working area, and the remaining layout stays together on the other side with its internal split ratios preserved. The working area respects outer gaps, reserved workspace-bar space, the menu bar, and the Dock; dropping outside it cancels the move.

In Dwindle, tile and workspace-edge insertions aim for an equal split where window minimum sizes allow. Tab groups move together, within the same workspace. Outside workspace-edge and internal-divider targets, dropping over the source tile or outside another tile cancels the move. An outer-edge insertion requires another visible tile and is unavailable while a visible tile is fullscreen. The action and preview follow the pointer during the drag, and the final release position determines the result. Multi-finger window-move gestures keep their existing swap behavior.

In Dwindle, dropping between existing splits inserts at their internal divider. A narrow band, up to 12 points on either side of the divider, offers this target after at least 10 points of pointer travel. Workspace-edge targets take precedence; where bands overlap, a divider inside a branch takes precedence over its enclosing divider. The preview highlights half the region after the divider: the right-hand region for side-by-side branches, or the upper region for stacked branches. The dragged tile shares that region equally with its existing layout, subject to window minimum sizes. The original divider ratio and the retained subtrees' internal ratios are preserved. Both branches must contain a visible tile other than the source, and a visible fullscreen tile disables this insertion.

You can also drop on another display. The same targets apply to the workspace shown there, and dropping where no window is moves the window or group into that workspace. Moves work between Niri and Dwindle in any combination. A Dwindle tab group moves as a whole and becomes one tabbed column in Niri, in a column of its own even on a stacking edge; set **Dwindle Group Across Displays** in **Settings → Mouse & Trackpad** to move only the dragged window. A swap that would not fit the other slot is refused, and dropping on a fullscreen space cancels.

Enable **Keep Native Moves Across Displays** in **Settings → Mouse & Trackpad** (`gestures.adoptNativeMoveAcrossDisplays = true`) to drag a tiled window by its title bar onto another display without holding a modifier. The real window follows the native drag, and release uses the same cross-display placement, group and focus rules described above. The setting defaults to off. Title-bar moves within one display still snap back, and native edge resizing keeps its separate setting.

## Resize with a right-drag

Hold the configured right-mouse resize modifier (`Option` by default) and right-drag a tiled window to resize it in either layout.

## Scroll the strip with a mouse wheel

Hold `Option + Shift + Mouse Scroll Wheel` (default, configurable) to scroll along the active Niri primary axis: left/right in horizontal orientation or up/down in vertical orientation.

## Trackpad gestures

Use three or four fingers (configurable) to scroll along the active Niri primary axis; direction can be inverted. Workspace switching and window move/resize also support two fingers, but column scrolling does not.

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
