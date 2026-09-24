---
title: Settings Reference
description: Complete reference for every table, array, key, and default in OmniWM's settings.toml.
sidebar:
  order: 2
---

This reference follows current `main`; features newer than the latest release are marked **Unreleased**.

Complete reference for `settings.toml`, in the file's canonical order. The authoritative schema is [`CanonicalTOMLConfig.swift`](https://github.com/OmniNull/OmniWM/blob/main/Sources/OmniWM/Core/Config/CanonicalTOMLConfig.swift); defaults come from [`SettingsExport.swift`](https://github.com/OmniNull/OmniWM/blob/main/Sources/OmniWM/Core/Config/SettingsExport.swift) and [`BuiltInSettingsDefaults.swift`](https://github.com/OmniNull/OmniWM/blob/main/Sources/OmniWM/Core/Config/BuiltInSettingsDefaults.swift).

:::caution
The current schema is strict — a missing required key in a version 3 file invalidates the whole file, `hotkeys` must list every assignable action exactly once, and an enumerated string key must use one of its listed values (an unknown value rejects the whole file, exactly like a missing key). Conflicting trackpad gesture finger counts under [`gestures`](#gestures) reject the whole file too. Edit values in place; see [Configuration](/config/configuration/).
:::

**Conventions**

- Keys marked *(optional)* may be omitted; every other key is required.
- **Colors** are tables with `red`, `green`, `blue`, `alpha` floats in `0.0`–`1.0`.
- **`singleWindowFit`** values are strings: `"fill"`, a custom size `"WIDTHxHEIGHT"` (e.g. `"1920x1080"`), or — Niri only — `"container_primary_span"`. `"fill"` is the Settings window's "Full Screen" fit: the lone window takes the fullscreen layout frame, so it follows `fullscreenUsesOuterGaps` rather than the regular tiling gaps.
- Values listed as enums accept exactly the raw strings shown.

## File schema

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `schemaVersion` | integer | `3` | Version of the complete `settings.toml` schema. This top-level key appears before the first table. |

The canonical file declares:

```toml
schemaVersion = 3
```

An absent version identifies a legacy version 0 file, while OmniWM v0.6.4 emitted version 1. OmniWM upgrades version 0, 1, and 2 files sequentially in memory before strict version 3 validation, retaining the compatibility guarantee for settings emitted by v0.6.2 through v0.6.4. The version 2 to version 3 step moves the old flat routing rows into one saved arrangement. A successful upgrade creates an exact write-once `settings.toml.pre-v3` or `settings.toml.pre-v3.1` backup, then atomically rewrites canonical TOML once; this can reorder keys and removes comments, while preserving unrecognized keys when their owner can be matched safely. Valid release migrations never use the `.corrupt` recovery slots. Older schema-less files are attempted but remain untouched with defaults active if they cannot validate, and files declaring a newer unsupported version remain untouched with configuration writes blocked. See [Automatic version upgrades](/config/configuration/#automatic-version-upgrades) for the migration rules and recovery behavior.

## general

Global switches: hotkeys, Hyper key, default layout, sleep, updates, IPC, animations.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `hotkeysEnabled` | boolean | `true` | Master switch for all global hotkeys. |
| `systemHyperTrigger` | string | `"None"` | Physical trigger for Hyper: `None`, a key name (`CapsLock`, `F13`–`F20`, `LeftControl`/`RightControl`, `LeftOption`/`RightOption`, `LeftShift`/`RightShift`, `LeftCommand`/`RightCommand`; OmniWM writes these with a space, for example `"Left Control"` and `"Caps Lock"`, and accepts both spellings), or `MouseButton3`/`MouseButton4`/`MouseButton5`. |
| `hyperKeyModifiers` | string | `"Control+Option+Shift+Command"` | Modifier set Hyper expands to: `+`-joined names, at least two of Control/Option/Shift/Command. |
| `defaultLayoutType` | string | `"niri"` | Layout used by workspaces whose own `layoutType` is `default`: `niri` or `dwindle`. |
| `preventSleepEnabled` | boolean | `false` | Prevents idle display sleep while your user session is active. |
| `updateChecksEnabled` | boolean | `true` | Automatic update checks. |
| `ipcEnabled` | boolean | `false` | Enables the IPC server used by `omniwmctl`. |
| `animationsEnabled` | boolean | `true` | Animates window layout changes and other OmniWM-authored motion. macOS Reduce Motion turns them off regardless of this key. |

## focus

Pointer-driven focus and monitor-edge focus/move behavior.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `followsMouse` | boolean | `false` | Focuses a managed window when the pointer enters it, no click needed. |
| `raiseOnMouseFocus` | boolean | `false` | Also raises the window when focus-follows-mouse focuses it. |
| `lockModifier` | string | `"off"` | Modifier that holds focus in place while pressed: `off`, `option`, `leftOption`, `rightOption`, `command`, `leftCommand`, `rightCommand`, `control`, `leftControl`, `rightControl`, `shift`, `leftShift`, `rightShift`. |
| `moveMouseToFocusedWindow` | boolean | `false` | Moves the pointer to the window that gains focus. |
| `followsWindowToMonitor` | boolean | `false` | Follows ordinary window or column transfers to another workspace, including dedicated monitor-move actions. Edge-crossing moves always follow. |
| `crossesMonitorAtEdge` | boolean | `false` | Directional focus continues onto the neighboring monitor at the screen edge. |
| `moveCrossesMonitorAtEdge` | boolean | `false` | Directional window move continues onto the neighboring monitor at the workspace edge and always follows the moved window. |

## mouseWarp

Cursor warping across the monitor arrangement (used with `routing.mode = "custom"`).

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `margin` | integer | `1` | Edge margin in pixels used when warping the cursor between monitors. |
| `enabled` | boolean | `true` | Enables cursor warping between monitors. |
| `constrainToArrangement` | boolean | `false` | Constrains the cursor to the configured monitor arrangement. |

## routing

How monitors are arranged for cross-monitor focus, move, and warp.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `mode` | string | `"macOS"` | `macOS` follows the system display arrangement; `custom` selects a saved arrangement for the connected displays. |
| `arrangements` | array of tables | `[]` | Saved custom routing grids, written as `[[routing.arrangements]]` with nested `[[routing.arrangements.monitors]]` rows. |

Each arrangement has a required `id` UUID and a required `monitors` array. Each monitor row requires `monitorName`, `gridColumn`, and `gridRow`; `monitorDisplayUUID` and `monitorDisplayId` are optional identity fields. Grid coordinates are integers. Settings records display UUIDs automatically; matching uses UUID first and the existing display-ID/name fallback for displays without UUIDs.

OmniWM selects the first exact connected-set match. Otherwise, it selects the arrangement with the fewest total rows that contains every connected display; the first arrangement wins ties. It then uses only the connected displays' grid positions. An uncovered set or an invalid selected grid follows macOS. Resolution, enumeration order, and macOS placement do not affect selection.

Editing, resetting, or finishing Monitor Setup saves exactly the connected set and retains an existing exact arrangement's ID. An edit to an inherited grid creates a separate arrangement without changing its larger source. Connecting displays or opening Settings does not create arrangements. Keep arrangement IDs stable when editing by hand so unrecognized configuration fields remain associated with the right arrangement.

```toml
[routing]
mode = "custom"

[[routing.arrangements]]
id = "FBE84D50-689B-4B97-A820-B8E3BFD581B7"

[[routing.arrangements.monitors]]
gridColumn = 0
gridRow = 1
monitorDisplayUUID = "8D575171-D0DD-43BB-9FEF-356E6B7C917D"
monitorName = "Built-in Retina Display"

[[routing.arrangements.monitors]]
gridColumn = 0
gridRow = 0
monitorDisplayUUID = "3EFD184C-D5D3-40EF-AF27-14C4222A467B"
monitorName = "DELL U2720Q"
```

For no saved arrangements, use `arrangements = []` inside `[routing]` and omit the array-of-table entries. The example UUIDs above are illustrative; use the identities recorded for your displays by **Settings > Monitors**.

## monitors

Optional table that ranks displays for OmniWM's monitor roles. Omit it to keep the default roles: **Main** is the display with the macOS menu bar, and **Secondary** and **Tertiary** are the next displays in arrangement order.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `ranking` | array of tables | unset | Displays in preference order, written as `[[monitors.ranking]]` rows. The highest-ranked connected display is Main, the next connected one is Secondary, the third is Tertiary, and unranked displays follow in the default order. |

Each row requires `name`; `displayUUID` and `displayId` are optional identity fields that Settings records automatically. A row with a `displayUUID` matches only that display. A row without one falls back to the display-ID/name pair, and then to a case-insensitive name match when it identifies exactly one connected display. A row whose display is disconnected is skipped, so a docked external display can outrank the built-in display while the built-in display becomes Main again when undocked.

```toml
[[monitors.ranking]]
displayUUID = "3EFD184C-D5D3-40EF-AF27-14C4222A467B"
name = "DELL U2720Q"

[[monitors.ranking]]
displayUUID = "8D575171-D0DD-43BB-9FEF-356E6B7C917D"
name = "Built-in Retina Display"
```

Workspaces whose home is Main, Secondary, or Tertiary follow this ranking, and so does the Quake terminal's `mainMonitor` mode. The `is-main` field and selector in `omniwmctl` keep reporting the macOS main display.

## gaps

Gaps between tiled windows and screen edges (points).

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `size` | float | `16.0` | Stored inner gap between tiled windows. An enabled focus border may raise the runtime-effective gap without rewriting this value. |
| `fullscreenUsesOuterGaps` | boolean | `false` | Fullscreen layout frames keep the outer gaps. |
| `outer.left` | float | `0.0` | Outer gap at the left screen edge. |
| `outer.right` | float | `0.0` | Outer gap at the right screen edge. |
| `outer.top` | float | `0.0` | Outer gap measured from the physical top edge of each display. The menu bar height is subtracted first and the result is clamped at 0, so a display without a menu bar needs a smaller value than the main display for the same visual gap below the menu bar. |
| `outer.bottom` | float | `0.0` | Outer gap at the bottom screen edge. |

Per-display values come from [`[[monitorGapOverrides]]`](#per-monitor-overrides). An override row must match the connected display’s UUID, or both display ID and name if that display has no UUID. An unmatched row is ignored and the global values apply; the override row’s own `id` does not identify the display.

## niri

Options for the scrolling (Niri) layout.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `visibleContainerCount` | integer | `2` | How many containers (columns) share the viewport side by side. |
| `infiniteLoop` | boolean | `false` | Treats the column strip as a loop instead of a bounded row. |
| `centerFocusedColumn` | string | `"never"` | When to center the focused column: `never`, `always`, `onOverflow`. |
| `alwaysCenterSingleColumn` | boolean | `false` | Centers the column when a workspace holds only one. |
| `singleWindowFit` | string | `"fill"` | Size of a lone window: `fill` (the "Full Screen" fit, which uses the fullscreen layout frame and honors `fullscreenUsesOuterGaps`), `container_primary_span`, or `WIDTHxHEIGHT`. |
| `containerPrimarySpanPresets` *(optional)* | float array | `[1/3, 1/2, 2/3]` | Span fractions the span-cycling actions step through. |
| `defaultContainerPrimarySpan` *(optional)* | float | `0.5` | Primary-axis span fraction for new containers. |

## dwindle

Options for the Dwindle (BSP) layout.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `smartSplit` | boolean | `false` | Automatically chooses the split direction based on cursor position. |
| `defaultSplitRatio` | float | `1.0` | `1.0` = equal split, `<1.0` = first window smaller, `>1.0` = first window larger. |
| `splitWidthMultiplier` | float | `1.0` | Biases when vertical vs. horizontal splits are preferred. |
| `singleWindowFit` | string | `"fill"` | Size of a lone window: `fill` (the "Full Screen" fit, which uses the fullscreen layout frame and honors `fullscreenUsesOuterGaps`) or `WIDTHxHEIGHT` (no span mode in Dwindle). |
| `useGlobalGaps` | boolean | `true` | Uses the [`gaps`](#gaps) values; when `false`, the inner gap comes from a per-monitor `innerGap` override (falling back to `gaps.size`), clamped to the same 0–64 range as `gaps.size`. |
| `moveToRootStable` | boolean | `true` | Keeps a window on the same screen side when moving it to the root. |

## borders

Border drawn around the focused window.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | Draws the focused-window border. |
| `width` | float | `5.0` | Exterior border width in points; configured values are clamped to 1–12 points when applied. Managed layout frames use its physical-pixel ceiling as the minimum runtime inner and outer clearance while borders are enabled; stored gap values are unchanged. |
| `color` | color table | red ≈ `0.0846`, green `1.0`, blue ≈ `0.9793`, alpha `1.0` | Border color (default is a cyan accent) used in light appearance. |
| `darkColor` | optional color table | absent | Border color used when macOS is in dark appearance. Falls back to `color` when absent. The glow also inherits it unless `glow.color` or `glow.darkColor` is set. |
| `gradient` | optional table | absent | Enables a two-color linear gradient border when `enabled = true`. |
| `gradient.enabled` | boolean | `false` | Uses the gradient instead of the solid border color. |
| `gradient.direction` | string | `"topLeftToBottomRight"` | Either `topLeftToBottomRight` or `topRightToBottomLeft`, in the border surface's local coordinates. |
| `gradient.start` / `gradient.end` | color tables | — | Complete endpoint colors. A present gradient table must include both colors. |
| `gradient.dark` | optional table | absent | Dark-appearance endpoint colors. |
| `gradient.dark.start` / `gradient.dark.end` | color tables | — | Endpoint colors used in dark appearance. Each stop falls back to the matching `gradient.start` / `gradient.end` value when absent. |
| `glow` | optional table | absent | Adds a visual-only glow around the border. It never changes layout gaps or resize hit-testing. |
| `glow.enabled` | boolean | `false` | Draws the glow before the border. |
| `glow.radius` | float | `8.0` | Glow radius in points, accepted from `0` through `32`. The overlay surface expands to contain it. |
| `glow.opacity` | float | `0.6` | Glow opacity from `0` through `1`. |
| `glow.color` | optional color table | absent | Overrides the glow color in light appearance. When absent, the glow inherits the border's solid color or gradient endpoints. |
| `glow.darkColor` | optional color table | absent | Glow color used in dark appearance. Falls back to `glow.color`, then to the border colors. |

Gradient and glow are composable. A missing table preserves solid rendering. Non-finite or structurally invalid values preserve the previous valid appearance; finite gradient color components are clamped to `0...1`, while glow radius and opacity must remain within their documented ranges. Glow reuses the border's solid color or gradient endpoints unless `glow.color` or `glow.darkColor` overrides it, so a gradient border produces a spatially matching gradient glow by default.

Border and gradient colors resolve per macOS appearance: dark values apply when the system (or OmniWM's own Appearance setting, when not Automatic) uses the dark appearance, and update live as the appearance switches — no restart needed. Unset dark values keep the base colors, so existing configs render exactly as before. In Settings, inherited colors are labeled explicitly; Customize creates an override and Reset restores inheritance. Editing one dark gradient endpoint leaves the other inherited until customized. The glow inherits the resolved border color or gradient endpoints, so it adapts with them.

## overview

Zoom and colors for the Overview.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `zoom` | float | `1.0` | Overview zoom factor. |
| `backdrop` | color table | `0.05, 0.05, 0.08, 1.0` | Backdrop behind the zoomed-out workspaces. |
| `windowBorders.normal` | color table | `0.3, 0.3, 0.35, 0.5` | Border for windows at rest. |
| `windowBorders.hovered` | color table | `0.4, 0.6, 1.0, 1.0` | Border for the hovered window. |
| `windowBorders.selected` | color table | `0.3, 0.8, 0.4, 1.0` | Border for the selected window. |

## workspaceBar

The per-monitor workspace bar. Per-monitor exceptions live in [`monitorBarOverrides`](#per-monitor-overrides).

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | Shows the workspace bar. |
| `showLabels` | boolean | `true` | Shows workspace names next to their numbers. |
| `showFloatingWindows` | boolean | `false` | Includes floating windows' icons in workspace pills. |
| `windowLevel` | string | `"popup"` | Bar window level: `normal`, `floating`, `status`, `popup`, `screensaver`. |
| `position` | string | `"overlappingMenuBar"` | `overlappingMenuBar` or `belowMenuBar`. |
| `notchMode` | string | `"moveBelowMenuBar"` | Notch handling: `off`, `moveBelowMenuBar`, `splitActiveLeft`, `splitActiveRight`, or `fillLeftOfNotch`. The last fills the menu-bar area left of the notch and covers app menus; without a notch it uses the left half of the menu bar. In this mode `position`, `xOffset`, `yOffset`, `height`, and `reserveLayoutSpace` are ignored: the bar uses the menu-bar height and reserves no layout space. |
| `notchActiveZoneWidth` | float | `180.0` | Width in points of the active zone around the notch. |
| `systemStatsButton` | boolean | `false` | Adds a system stats button to the bar. |
| `deduplicateAppIcons` | boolean | `false` | Collapses repeated icons of the same app within a pill. |
| `hideEmptyWorkspaces` | boolean | `false` | Hides pills for workspaces with no windows. |
| `excludedBundleIDs` | string array | `[]` | Bundle IDs whose windows never contribute icons to the bar. |
| `iconOverrides` | table | `{}` | Bundle ID → custom icon source (see below). |
| `reserveLayoutSpace` | boolean | `false` | Reserves tiled layout space using the configured bar height. |
| `revealModifier` | string | `"off"` | Reveal the bar by holding a modifier. Any value other than `off` makes the bar overlay-only: it reserves no layout space at all while the modifier is configured, not just while it is held. Values: `off`, `option`, `control`, `command`, `shift`, `controlOption`, `optionCommand`, `optionShift`, `controlCommand`, `controlShift`, `commandShift`, `controlOptionCommand`, `controlOptionShift`, `optionCommandShift`, `controlCommandShift`, `controlOptionCommandShift`. |
| `revealHoldMilliseconds` | float | `200.0` | How long the modifier must be held before the bar reveals. |
| `hideInNativeFullscreen` | boolean | `false` | Hides the bar while a native-fullscreen space is active. `fillLeftOfNotch` always hides there, regardless of this setting. |
| `height` | float | `24.0` | Bar height in points. |
| `backgroundOpacity` | float | `0.1` | Bar background opacity (`0.0`–`1.0`). |
| `inactiveIconOpacity` *(optional)* | float | unset | Opacity of unfocused app icons; finite values clamp to `0.0`–`1.0`. Omit to use the built-in appearance; Reset to System Default clears the override. |
| `transparentBackground` *(optional)* | boolean | `false` | Hides the bar material, tint, and border while keeping its contents interactive. Takes precedence over `solidBlackBackground`. |
| `solidBlackBackground` *(optional)* | boolean | `false` | Uses a solid black bar background when `transparentBackground` is false. |
| `showItemBackgrounds` *(optional)* | boolean | `true` | Shows backgrounds behind workspace groups, floating windows, scratchpads, and stats. |
| `showAccentHighlights` *(optional)* | boolean | `true` | Shows the focused-workspace outline and focused-icon glow. |
| `xOffset` | float | `0.0` | Horizontal offset in points. |
| `yOffset` | float | `0.0` | Vertical offset in points; positive values move the bar up, negative values move it down. |
| `accentColor` *(optional)* | color table | unset | Accent color override; unset uses the built-in accent. |
| `textColor` *(optional)* | color table | unset | Text color override; unset uses the built-in text color. |

`iconOverrides` maps a bundle ID to either an image file path — absolute, `~/`-relative, or relative to the `omniwm` config directory — or `bundle-resource:NAME` for an image resource inside that app's own bundle:

```toml
[workspaceBar.iconOverrides]
"com.apple.Safari" = "~/Pictures/safari-alt.png"
"com.mitchellh.ghostty" = "bundle-resource:AppIcon"
```

## gestures

Mouse and trackpad gestures.

The seven optional `overviewGesture…` and `window…` keys below configure Overview swipes and trackpad window move/resize.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `scrollEnabled` | boolean | `true` | Trackpad column scrolling (`fingerCount`) and modifier + mouse scroll wheel scrolling along the Niri primary axis; `false` turns off both. |
| `scrollSensitivity` | float | `5.0` | Scroll gesture sensitivity. |
| `scrollModifierKey` | string | `"optionShift"` | Modifier for wheel scrolling: `optionShift` or `controlShift`. |
| `mouseMoveModifierKey` | string | `"option"` | Modifier for drag-to-swap of tiled windows in Niri and Dwindle (Niri also accepts `Shift` for insert): `off`, `option`, `control`, `command`, `controlOption`, `optionCommand`, `controlCommand`, `controlOptionCommand`. |
| `mouseResizeModifierKey` | string | `"option"` | Modifier for right-drag resize: `option`, `control`, `command`, `shift`, `controlOption`, `optionCommand`, `optionShift`, `controlCommand`, `controlShift`, `commandShift`, `controlOptionCommand`, `controlOptionShift`, `optionCommandShift`, `controlCommandShift`, `controlOptionCommandShift`. |
| `fingerCount` | integer | `3` | Trackpad column-scroll finger count: `2`, `3`, or `4`. |
| `invertDirection` | boolean | `true` | Inverts trackpad gesture direction. |
| `trackpadScrollStyle` | string | `"snap"` | `snap` (snap to columns) or `momentum`. |
| `workspaceSwipeEnabled` | boolean | `false` | Trackpad swipe switches to the next/previous workspace. |
| `workspaceSwipeFingerCount` | integer | `3` | Workspace-swipe finger count: `2`, `3`, or `4`. |
| `workspaceSwipeAxis` | string | `"vertical"` | Workspace-swipe axis: `horizontal` or `vertical`. |
| `overviewGestureEnabled` *(optional)* | boolean | `false` | Enable the trackpad gesture that opens Overview with an upward swipe and closes it with a downward swipe. |
| `overviewGestureFingerCount` *(optional)* | integer | `4` | Overview gesture finger count: `3` or `4`. |
| `windowMoveEnabled` *(optional)* | boolean | `false` | Drag without clicking to swap the tiled window under the cursor in either layout. |
| `windowMoveFingerCount` *(optional)* | integer | `4` | Window-move finger count: `2`, `3`, or `4`. |
| `windowResizeEnabled` *(optional)* | boolean | `false` | Drag without clicking to resize the tiled window under the cursor in either layout. |
| `windowResizeFingerCount` *(optional)* | integer | `3` | Window-resize finger count: `2`, `3`, or `4`. |
| `windowGestureSensitivity` *(optional)* | float | `1.0` | Move/resize sensitivity, clamped to `0.1…5.0`; non-finite values use `1.0`. |

Window move and resize gestures use all directions, so their finger counts must differ from every other enabled gesture. Configuration loading rejects overlaps with each other, column scrolling, workspace switching, or Overview. In Settings, **Set Up…** previews the conflicting assignments and lets you choose which gestures to turn off before applying the change. When editing TOML, disable or reassign conflicting gestures in the same edit. Moving stays on the starting monitor; resizing can continue beyond its bounds. Lift all fingers to finish, and turn off matching macOS gestures under System Settings → Trackpad → More Gestures. These gestures are inactive while Overview is open and do not use `invertDirection`.

Overview follows your fingers like Mission Control. Swipe up with the configured finger count and the thumbnails fly out as you move; release past the halfway point, or flick upward, to finish opening, and release earlier to cancel without disturbing the app you were in. Swipe down while Overview is open to close it the same way. Closing matches Escape: it activates the highlighted window, or restores the previously active app when there is no selection. Touching the trackpad while Overview is animating catches it in place. With `animationsEnabled` off or macOS Reduce Motion on, the swipe triggers immediately after a short travel instead of tracking. Direction is independent of `invertDirection`. Lift all fingers between gestures. Configuration validation rejects enabled gestures that share the same fingers and upward movement; the Settings **Set Up…** flow helps resolve those conflicts. Horizontal swipes may share fingers with Overview. Validation accounts for connected monitors' column orientations and workspace swipes running perpendicular to column scrolling when their finger counts match. Without column scrolling, workspace swipes use their configured axis. If a display change creates an overlap, ambiguous upward swipes are ignored until the assignments are corrected. Disable the matching macOS Mission Control gesture to avoid interception.

## statusBar

Extra readouts beside the menu bar icon.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `showWorkspaceName` | boolean | `false` | Shows the active workspace beside the menu bar icon. |
| `showAppNames` | boolean | `false` | Also shows the focused app's name. |
| `useWorkspaceId` | boolean | `false` | Shows the workspace number instead of its name. |

## hiddenBar

Menu-bar icon concealment (concealment requires macOS 27+).

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | Enables the Hidden Bar feature. |
| `hiddenBundleIDs` | string array | `[]` | Bundle IDs of menu-bar apps whose icons are concealed. |
| `rehideIntervalSeconds` | float | `5.0` | Seconds before revealed icons re-hide automatically. |

## clipboard

Clipboard history limits. History content itself is stored in the state directory, not in the config file.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `historyEnabled` | boolean | `false` | Enables clipboard history capture. |
| `maxItems` | integer | `200` | Maximum number of unpinned history entries. |
| `maxItemBytes` | integer | `8388608` | Maximum size of a single entry (8 MiB). |
| `maxTotalBytes` | integer | `67108864` | Maximum total history size, including pins (64 MiB). |
| `ignoredTypes` | string array | `[]` | Exact pasteboard type identifiers that exclude a copy from history. |

## quakeTerminal

The drop-down (Quake) terminal.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | Enables the Quake terminal. |
| `position` | string | `"center"` | Terminal position: `top`, `bottom`, `left`, `right`, `center`. Edge positions slide in; `center` fades in place. |
| `widthPercent` | float | `50.0` | Width as a percentage of the monitor's available screen area. |
| `heightPercent` | float | `50.0` | Height as a percentage of the monitor's available screen area. |
| `animationDuration` | float | `0.2` | Show/hide animation duration in seconds. |
| `autoHide` | boolean | `false` | Hides the terminal when it loses focus. |
| `opacity` *(optional)* | float | `1.0` | Terminal background opacity (`0.0`–`1.0`). |
| `backgroundEffect` | string | `"standardBlur"` | Background material: `standardBlur`, `glassRegular`, `glassClear`. |
| `backgroundBlurRadius` *(optional)* | integer | `0` | Background blur radius; `0` disables the extra blur. |
| `monitorMode` *(optional)* | string | `"focusedWindow"` | Which monitor it appears on: `mouseCursor`, `focusedWindow`, `mainMonitor`. |

## scratchpads

Optional labels for the ten scratchpad slots. A label replaces the slot number in the workspace bar and in `omniwmctl` output.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `labels` | table | `{}` | Slot number (`1`–`10`) → label string. |

```toml
[scratchpads.labels]
1 = "term"
2 = "notes"
```

## appearance

Appearance of OmniWM's own UI.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `mode` | string | `"dark"` | `automatic`, `light`, or `dark`. |
| `tabRailAppIcons` *(optional)* | boolean | `false` | Replaces compact tab markers with app icons in Niri and Dwindle. Each tab group reserves a 28-point rail instead of 10 points; crowded rails scroll vertically. |

The **Show app icons in tab rails** toggle in **Settings → General → Appearance** controls the same option. Changes apply live without restarting.

```toml
[appearance]
mode = "dark"
tabRailAppIcons = true
```

## hotkeys

Array of tables — one entry per assignable action, each with an `id` (the action identifier) and a `binding`:

```toml
[[hotkeys]]
binding = "Option+1"
id = "switchWorkspace.0"

[[hotkeys]]
binding = "Unassigned"
id = "toggleScratchpad.1"
```

- `binding` is a human-readable chord: `+`-joined modifiers (`Control`, `Option`, `Shift`, `Command`, or the `Hyper` shorthand for the full [`hyperKeyModifiers`](#general) set) followed by a key name — or `"Unassigned"`. A `Left `/`Right ` prefix pins a modifier to one side (e.g. `"Left Option+H"`).
- The array is validated strictly: every assignable action must appear **exactly once**. An unknown, unassignable, duplicate, or missing action id rejects the whole file, so rebind by editing `binding` values in place — never add or remove entries.
- The numeric suffix is zero-based for `switchWorkspace.N`, `moveToWorkspace.N`, `focusColumn.N`, and `moveColumnToWorkspace.N` — `switchWorkspace.0` is *Switch to Workspace 1* (`Option + 1` by default) — and one-based for `switchWorkspaceSlot.N`, `moveToWorkspaceSlot.N`, `focusWindowInColumn.N`, `moveColumnToIndex.N`, `toggleScratchpad.N`, and `assignFocusedWindowToScratchpad.N`.

The default bindings are listed in the [keyboard shortcuts guide](/guides/keyboard-shortcuts/); the full action list is visible in **Settings > Hotkeys** and via `omniwmctl query commands`.

## workspaces

Array of workspace definitions.

| Key | Type | Description |
| --- | --- | --- |
| `id` | string (UUID) | Stable identity; keep it unchanged when editing. |
| `name` | string | Workspace name; numeric names define the ordering and number-key targets. |
| `displayName` *(optional)* | string | Label shown in the bar instead of `name` (emoji welcome). |
| `monitorAssignment` | table | `type` = `main`, `secondary`, `tertiary`, or `specificDisplay`. For `specificDisplay`, the `output` sub-table contains a required `name` (string), optional `displayUUID` (string), and optional `displayId` (integer). The role types resolve through the [`monitors`](#monitors) ranking. |
| `layoutType` | string | `default` (follow `general.defaultLayoutType`), `niri`, or `dwindle`. |

For `specificDisplay`, `displayUUID` takes precedence when present. Without it, `displayId` and `name` must match a monitor that has no display UUID. A name alone cannot identify the target monitor.

Default: nine workspaces named `1`–`9`, all Niri — `1`–`5` and `8`–`9` on the main monitor, `6` (shown as ❤️) and `7` (shown as 🚀) on the secondary, matching the default `Option + 1`–`9` bindings.

```toml
[[workspaces]]
displayName = "❤️"
id = "5953F2BF-A378-4266-91B2-287174C4FA4D"
layoutType = "niri"
name = "6"

[workspaces.monitorAssignment]
type = "secondary"
```

## appRules

Array of per-app window rules, editable in the **App Rules** window. Matchers select windows; the remaining fields say what to do with them.

| Key | Type | Description |
| --- | --- | --- |
| `id` *(optional)* | string (UUID) | Stable rule identity; generated if omitted. Keep an existing ID unchanged when editing. |
| `bundleId` | string | App bundle ID to match (may be empty when an advanced matcher is used). |
| `appNameSubstring` *(optional)* | string | Matches on the app name. |
| `titleSubstring` *(optional)* | string | Matches on the window title. |
| `titleRegex` *(optional)* | string | Regex match on the window title; when both title matchers are set, the regex wins. |
| `axRole` *(optional)* | string | Matches the accessibility role. |
| `axSubrole` *(optional)* | string | Matches the accessibility subrole. |
| `layout` *(optional)* | string | `auto` (default), `tile`, or `float`. |
| `assignToWorkspace` *(optional)* | string | Workspace name the window is routed to. |
| `initialContainerPrimarySpan` *(optional)* | float | Initial Niri span for the window's container (`0.05`–`1.0`). |
| `minWidth` *(optional)* | float | Minimum layout width in points. |
| `minHeight` *(optional)* | float | Minimum layout height in points. |

The defaults ship 13 rules that set minimum sizes for apps with known resize floors (Codex, Commander One, Chrome, Zed, Safari, Zen, Firefox, Dia, Spotify, Discord, Ghostty, Outlook, Messages).

```toml
[[appRules]]
bundleId = "com.apple.Safari"
id = "81426D13-C1A5-475E-AFBC-00BBA05042D0"
minHeight = 220.0
minWidth = 574.0
```

## Per-monitor overrides

Five arrays hold per-monitor exceptions to the global tables. Every entry requires `monitorName`. Use the display’s `monitorDisplayUUID`; for a display without a UUID, supply both `monitorDisplayId` and `monitorName`. A name alone does not match a display. All entries except orientation also carry an `id` UUID identifying the override row, not the display. Override keys are all optional — an omitted key falls back to the corresponding global setting. All five arrays default to empty. Custom routing grids live separately in [`routing.arrangements`](#routing).

| Array | Overridable keys |
| --- | --- |
| `monitorBarOverrides` | `enabled`, `showLabels`, `showFloatingWindows`, `deduplicateAppIcons`, `hideEmptyWorkspaces`, `reserveLayoutSpace`, `notchMode`, `notchActiveZoneWidth`, `position`, `windowLevel`, `height`, `backgroundOpacity`, `inactiveIconOpacity`, `transparentBackground`, `solidBlackBackground`, `showItemBackgrounds`, `showAccentHighlights`, `xOffset`, `yOffset` — see [`workspaceBar`](#workspacebar) |
| `monitorOrientationOverrides` | `orientation`: `horizontal` or `vertical` layout orientation for that monitor |
| `monitorNiriOverrides` | `visibleContainerCount`, `centerFocusedColumn`, `alwaysCenterSingleColumn`, `singleWindowFit`, `infiniteLoop` — see [`niri`](#niri) |
| `monitorDwindleOverrides` | `smartSplit`, `defaultSplitRatio`, `splitWidthMultiplier`, `singleWindowFit`, `useGlobalGaps`, `innerGap` — see [`dwindle`](#dwindle) |
| `monitorGapOverrides` | `innerGap`, `outerGapLeft`, `outerGapRight`, `outerGapTop`, `outerGapBottom`, `fullscreenUsesOuterGaps` — see [`gaps`](#gaps) |

```toml
[[monitorGapOverrides]]
id = "0B54A3C1-6E1B-4D5B-9A64-2F0D8A11C001"
innerGap = 8.0
monitorDisplayUUID = "3EFD184C-D5D3-40EF-AF27-14C4222A467B"
monitorName = "DELL U2720Q"
outerGapTop = 4.0
```

The example UUID is illustrative; replace it with the identity recorded for your display. These overrides are most easily managed from **Settings > Monitors** and the per-layout tabs, which record the display's UUID automatically so the override survives display reconnects.
