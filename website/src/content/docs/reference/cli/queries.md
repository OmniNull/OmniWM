---
title: Queries
description: Query OmniWM windows, workspaces, displays, and registries with selectors and field projection.
sidebar:
  order: 3
---

```
omniwmctl query <name> [selectors...] [--fields <field1,field2,...>] [--format json|ndjson|table|tsv|text]
```

Default output format for queries is `json`.

## Query Selectors

Selectors filter query results. Value selectors take an argument; boolean selectors are flags.

**Value selectors:**

| Selector | Description |
|----------|-------------|
| `--window <id>` | Filter by session-scoped opaque window ID |
| `--workspace <name>` | Filter by workspace raw name, display name, or ID |
| `--display <name>` | Filter by display name or display ID |
| `--app <name>` | Filter by application display name |
| `--bundle-id <id>` | Filter by application bundle identifier |

**Boolean selectors:**

| Selector | Description |
|----------|-------------|
| `--focused` | Only the focused item |
| `--visible` | Only visible items; windows also require a visible workspace, no window hidden state, an app that is not hidden, and no WindowServer ordered-out state |
| `--floating` | Only floating windows |
| `--scratchpad` | Only windows assigned to a scratchpad |
| `--current` | Only the current/interaction item |
| `--main` | Only the main display |

## Query Fields

Use `--fields` with a comma-separated list to limit returned fields.

Field tokens are part of the CLI contract. Returned JSON still uses the payload schema's field names, so the selected token may not be byte-for-byte identical to the JSON key. For example, `window-counts` selects the workspace payload's `counts` field.

**Window fields:** `id`, `pid`, `window-id`, `workspace`, `display`, `app`, `title`, `frame`, `mode`, `layout-reason`, `manual-override`, `is-focused`, `is-fullscreen`, `is-visible`, `is-app-hidden`, `is-scratchpad`, `scratchpad-index`, `hidden-reason`, `column-index`

`window-id` returns the JSON field `windowId`, the raw CGWindowID of the window. It is stable for the window's lifetime but not session-scoped; keep using `id` for `window` actions.

For windows, `is-visible` is true only when the workspace is visible, the window has no `hidden-reason`, its macOS application is not hidden, and WindowServer has not reported the window as ordered out. If the WindowServer ordered-in state is unavailable, the other visibility checks determine the result. The `--visible` selector uses the same conditions.

`hidden-reason` selects the optional JSON field `hiddenReason`:

| Value | Meaning |
|-------|---------|
| `workspace-inactive` | Parked for an inactive workspace. |
| `tab-inactive` | Hidden as an inactive member of a Dwindle group or Niri tabbed column. |
| `layout-transient` | Other layout-owned hiding, including Niri columns outside the viewport and active members awaiting reveal. |
| `scratchpad` | Hidden by the scratchpad. |

Workspace and scratchpad hiding retain their reasons. For other layout hiding, an inactive tab reports `tab-inactive` even when its column is also outside the viewport. An active member awaiting reveal keeps `layout-transient` until its hidden state clears. `hiddenReason` is omitted when no hidden state is recorded; `layout-transient` can persist in a settled layout and is not an animation-completion signal.

`is-app-hidden` exposes the PID-scoped macOS hide state independently of `layout-reason` and `hidden-reason`; selecting `is-app-hidden` returns the JSON field `isAppHidden`.

`is-fullscreen` returns the JSON field `isFullscreen`: true while the window is in OmniWM's own fullscreen (`toggle-fullscreen`) in its workspace's active layout. Native macOS Full Screen is reported separately by `layout-reason`. The `focused-window` query always includes `isFullscreen` for the focused window.

`column-index` returns the JSON field `columnIndex`: the one-based Niri column that holds the window, numbered like `focus-column` and `move-column-to-index`. Inactive tabs share their column's index; floating windows, Dwindle windows, and windows excluded from the layout, such as minimized windows, omit it.

**Workspace fields:** `id`, `raw-name`, `display-name`, `number`, `layout`, `display`, `is-focused`, `is-visible`, `is-current`, `window-counts`, `focused-window-id`, `columns`

The three workspace flags answer different questions. `is-focused` marks the workspace that holds the natively focused managed window, `is-current` marks the active workspace on the interaction monitor (the one `--current` selects), and `is-visible` marks every workspace that is active on some monitor. With two monitors, two workspaces are visible, one is current, and at most one is focused.

`columns` lists a Niri workspace's columns in order as `{"index": 1, "viewport": "before"}` entries. `viewport` is `before` or `after` for a column entirely outside the viewport on that side and `intersecting` for a column that is at least partly visible. It describes the viewport's destination: a scroll animation reports its target immediately, and a trackpad drag keeps the previous value until release. Dwindle workspaces omit `columns`.

**Display fields:** `id`, `name`, `is-main`, `is-current`, `frame`, `visible-frame`, `has-notch`, `orientation`, `inner-gap`, `outer-gap-left`, `outer-gap-right`, `outer-gap-top`, `outer-gap-bottom`, `fullscreen-uses-outer-gaps`, `active-workspace`

`fullscreen-uses-outer-gaps` reports the resolved per-display policy used by OmniWM Full Screen, Niri maximized, and the Single Window “Full Screen” fit. It does not affect native macOS Full Screen.

`frame` and `visible-frame` use AppKit global screen coordinates as reported by `NSScreen`: the origin is the bottom-left corner of the main display and `y` grows upward, so a display above the main one has a larger `y` than the main display. Window `frame` values use the same coordinate space.

## Query Reference

| Query | Selectors | Fields | Description |
|-------|-----------|--------|-------------|
| `workspace-bar` | — | — | Workspace bar projection for every monitor; app pills carry `id`, `appName`, `bundleId` (omitted when unknown), `isFocused`, `windowCount`, and `allWindows` |
| `active-workspace` | — | — | Current interaction monitor and active workspace |
| `focused-monitor` | — | — | Current interaction monitor and its active workspace |
| `apps` | — | — | Managed app summary |
| `metrics` | — | — | Always-on runtime metrics: AX frame-write attempts and whole-attempt wall time (the setter plus its ordering/verification reads; enhanced-UI batch work and the retry element refresh are not counted) as since-launch totals plus live rows per app AX context, display tick timing, layout build counts, and process energy/CPU. Populated without an active `capture` session |
| `focused-window` | — | — | Focused managed window snapshot |
| `windows` | `--window`, `--workspace`, `--display`, `--focused`, `--visible`, `--floating`, `--scratchpad`, `--app`, `--bundle-id` | window fields | Managed windows |
| `workspaces` | `--workspace`, `--display`, `--current`, `--visible`, `--focused` | workspace fields | Configured workspaces with occupancy |
| `displays` | `--display`, `--main`, `--current` | display fields | Connected displays with geometry |
| `rules` | — | — | Persisted user window rules |
| `rule-actions` | — | — | Rule action registry |
| `queries` | — | — | Query registry |
| `commands` | — | — | Automation action registry for `command`, `workspace`, `window`, and `window mark` surfaces |
| `subscriptions` | — | — | Subscription registry |
| `capabilities` | — | — | Full protocol capabilities, including `windowMarkActions` |

`window mark` descriptors in `commands` and `capabilities` are available. List live marks with [`omniwmctl window mark list`](/reference/cli/actions/#window-marks).

**Examples:**

```bash
# List all windows on workspace 1
omniwmctl query windows --workspace 1

# Get focused window in table format
omniwmctl query focused-window --format table

# List visible floating windows, only return id and title
omniwmctl query windows --visible --floating --fields id,title

# Get the active workspace on the current interaction monitor
omniwmctl query workspaces --current

# Check server capabilities
omniwmctl query capabilities
```
