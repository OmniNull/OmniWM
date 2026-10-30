---
title: Islands and components
description: Configure persistent Dynamic Islands, Lake component instances, placement, and editable integrations.
sidebar:
  order: 3
---

A Dynamic Island is a persistent surface whose root widget chooses compact, preview and expanded content. Components provide reusable views and integrations inside that root. Follow [Build a Dynamic Island](/omnishell/guides/dynamic-island/) to create a separate profile and your first component.

## Enable and place an island

Choose **Default**, or **Lake** once it is installed, in **Settings > Styles & Widgets**, then open **Island**. Using a style changes the shared profile for the bar and island without changing either enable switch.

Lake’s **Island** tab provides **Add Widget…**, per-instance enable switches, drag to reorder, and **Remove**. Selecting an instance opens its options editor, which assigns it to Automatic, Main, Side, or Expanded Only placement and exposes its declared options. **Appearance** controls the island’s shape and colors; **Actions** and **Hover and Swipe** control click, right-click, hover, and swipe behavior, with motion tuning under **Advanced Motion**. **Placement** chooses displays, native fullscreen behavior, and advanced surface dimensions.

Default’s Focus Ribbon builds its content automatically from the active workspace and focused window. Its Island tab explains that behavior; it does not use Lake’s component catalog. Both islands can be configured while disabled and run without the Workspace Bar. The native settings file stores the master switch as `[island] enabled = true`; placement belongs to the selected shell profile:

```toml
# In a profile folder's shell.toml:
[island]
root = "my-island"
displays = "notch"
width = 760
height = 300
fullscreen = "hide"
```

In the user shell file, use `[profiles.<profile>.island]` instead. An absent island table places no island. `root` defaults to `focus-ribbon`; that widget must exist in a configured widgets folder. `displays` accepts `notch`, `main`, or `all`. `fullscreen` accepts `hide` (default) or `show`. Width and height are the fixed panel envelope in points, from 1 to 8192, clamped to each display. Change the Luau tree's size to expand or collapse its contents; the window does not resize with those transitions.

## Reserve space for authored islands

A profile can reserve window-layout space for an island through `[island.room]`. The reservation applies only while the island and Workspace Bar are enabled on a display included by the island's `displays` selector. Selecting a profile does not change those enable switches.

```toml
[widgets.my-island]
layout = "island"
barSize = 1
pins = []
dockOverlap = false

[island.room]
setting = "layout"
size = "barSize"

[island.room.variants.island]
top = { base = 8, scaled = 54, mode = "add" }
dock = "bottom"

[island.room.variants.frame]
top = { base = 24, mode = "total", clear = "notch" }
left = { base = 14, scaled = 62.1, mode = "total" }
right = { base = 24, mode = "total" }
bottom = { base = 24, mode = "total" }
dock = "right"

[island.room.dock]
base = 23.8
scaled = 45.9
when = ["pins"]
unless = "dockOverlap"
```

`setting` names a string setting on the configured island root; its value selects a named variant. `size` optionally names a numeric root setting, defaulting to 1 when absent. Each edge resolves to `floor(base + scaled * size + 0.5)` points; `base` and `scaled` default to zero. Values must resolve to finite nonnegative sizes. Unknown fields, invalid declarations and missing variants report a configuration problem and reserve no room.

An edge's `mode` is `add`, to add space to the usual gap and bar reservation, or `total`, to replace the outer gap with the requested window-edge distance. Top distances start at the display's top edge; the other edges start at its visible bounds. Top alone accepts `clear = "none"`, `"notch"` or `"menuBar"` to add that display's corresponding height. Niri and Dwindle tiles both meet a `total` edge exactly, whether or not Niri's screen-edge gaps are on.

The optional dock reservation raises its variant's `dock` edge to at least its resolved distance when any setting in `when` is `true` or a nonempty list, unless the `unless` setting is `true`. Reservations also bound `island.usableRect`, IPC reserved-inset queries and fullscreen layouts that omit user outer gaps. Changing the selected variant, size or display selector uses the normal profile-override relayout path.

## Root geometry and display data

The root's `render(ctx)` receives `ctx.data.island`. It is `nil` in ordinary bar instances. It contains `display`, `size = {w, h}`, optional `notch = {x, w, h}`, `menuBar`, `scale`, `main`, `visible`, `fullscreen`, and `focused`. Coordinates start at the envelope's top left. `focused` reflects the island’s native keyboard focus lease. A focusable element can acquire it by clicking, and blur, a declared Escape key or an outside press releases it. A root can also appear in a bar lane, using a separate `ctx.state` for each placement and display.

`island.navigation` describes that display’s active workspace: `workspace` is its stable name, `name` its display label, `layout` is `niri` or `dwindle`, and optional `focused` is the selected managed window’s opaque ID. `windows` contains one entry per window with `id`, `bundle`, `name`, `title`, and `column` (one-based Niri column, or zero outside the Niri tree). Entries follow Niri column and row order, with floating windows after tiled windows. Titles use existing cached metadata and may be empty; use the app name as a fallback. Pass an ID to `omniwm.run("window focus " .. id)` to focus it. This data follows workspace and managed-selection changes without polling or per-frame Luau updates.

The island survives opening a popout or drawer and disabling the Workspace Bar. A hidden fullscreen island keeps its Luau instance and state, suspends rendering, and resumes with current data when shown. Its view-only data demand is suspended too. See the [Luau API reference](/omnishell/reference/) for components, timers, durable state, providers, motion, text entry, file resources and desktop services.

## Pointer handling

Transparent-window click-through still needs a live check on the target macOS system. OmniWM's own mouse handling uses cached visible/actionable rectangles, preserving gaps between capsules; these rectangles conservatively cover rounded corners and path holes.

## Default Focus Ribbon

Default also includes **Focus Ribbon**. Turn on **Settings > Styles & Widgets > Island > Show Dynamic Island** to show its compact black island at the top of each display. Navigating Niri windows or switching workspaces expands the same island into a ribbon of that workspace’s window icons, in column order. Short ribbons stay centred; longer ribbons follow the focused window within the list’s edges. Each window has its own icon, including multiple windows from one app, with the focused window’s title beneath the ribbon or its app name when no title is available. The ribbon stays open while the pointer is inside and otherwise collapses 2.6 seconds after the last navigation or pointer exit; click the compact island to reopen it, click an icon to focus that window, or click outside to collapse. It does not take keyboard focus. The island hides in native fullscreen and works when the workspace bar is disabled.

## Lake and configured instances

The optional `lake` style draws its island in editable Luau. Its bar lanes remain independently configurable: custom bar widgets and an island can run together. The native **Show Dynamic Island** switch controls whether the island is present; selecting a profile does not turn it on. The profile uses a short hover dwell to show a preview, a click to expand, native button press feedback, an upward pointer/trackpad gesture to collapse, and outside press or Escape to dismiss. The primary capsule accepts keyboard focus on click in compact, preview and expanded modes. While focused, Left and Right cycle enabled components in configured order; Escape dismisses the expanded content and releases focus. Collapsing with a click or gesture may leave the compact capsule focused until Escape, blur or an outside press.

These choices live in `widgets/lake/init.luau` and `lib/lake/intent.luau`, `policy.luau`, `slots.luau` and `motion.luau`. Replace them independently of `lib/lake/services/` to retain integrations. The profile requests gesture boundaries only; its UI does not run Luau for every pointer move. Native capture and automated tests do not establish perceived motion quality: hover dwell, press feel, trackpad direction and focus restoration still need a live check on the target display.

Configure instances in the selected profile's `shell.toml`, or override the entire list under `[[profiles.lake.island.components]]` in your top-level `shell.toml`:

```toml
[[island.components]]
id = "london"
widget = "world-clock"
zone = "Europe/London"
label = "London"

[[island.components]]
id = "tokyo"
widget = "world-clock"
zone = "Asia/Tokyo"
label = "Tokyo"
```

Each `id` has its own validated options and shared `instance.state`; `ctx.state` is separate for each display and placement. Disabling an instance runs its `deinit` hook. Editing options calls `options(instance, previous)` without restarting the root. Up to 64 configured instances share the root's VM.

Each configured instance chooses an installed component package. Packages live in a widgets directory with `component.toml` metadata and `component.luau` views. The root discovers them through `ctx.data.components` and mounts a view with `ui.component`. View names and promotion policy belong to the root. The [component reference](/omnishell/reference/components-configuration/) covers manifests, lifecycle hooks, options and mount behavior.

## Customize the Lake profile

Expand the island and press the sliders button, or right-click its main capsule. **Components** lets you add installed packages, enable or disable instances, remove them, and edit their declared options. Drag an instance's grip to reorder it; after focusing a row, Up and Down also move it. **Show** opens that instance. Boolean, number, choice, text and string-list options are editable here. Text fields use Command + Return to save and Escape to cancel. Lists preserve empty values and newlines, offer Add/Remove, and show twelve entries per page. A Saving notice remains until the configuration write completes; admission, schema and disk errors stay visible.

Region choices are lake's own policy: **Automatic** participates in the normal main/side selection; **Main** prefers the main capsule; **Side** occupies the smaller capsule; **Expanded only** is available after expansion. A manually selected component can become the main expanded view. These meanings are implemented in `lib/lake/policy.luau`, and can be replaced along with the rest of the profile. Bar widgets remain independently configurable.

**Appearance**, **Interaction** and **Motion** expose expanded width, corner radius, solid background and selected-tab colors, hover preview timing, click/right-click/swipe targets, swipe direction/input/distance and expansion spring parameters. Colors use `#RRGGBB` or `#RRGGBBAA`. Action targets are `toggle`, `expand`, `collapse`, `settings`, `next`, `previous`, `none`, or `component:<enabled instance ID>`; a component target promotes and expands that instance. Unavailable component targets do nothing. The sliders button still opens settings even when the right-click target changes. These are profile controls; each component retains its own declared options and editable views.

These change the layer-rendered contents; the persistent island window retains its configured envelope. The fixed envelope clamps a requested content width that cannot fit.

Root settings and their validation schema live in `widgets/lake/settings.toml`, while current values are saved in the selected profile's user configuration. The settings view is itself editable Luau in `lib/lake/settings.luau`.

The native **Settings > Styles & Widgets > Island** editors provide the same declared widget options and profile controls without requiring the island to be enabled. Use **Advanced Motion** for native motion tuning and **Placement** for display scope and surface dimensions.

## Editable Lake components

The `lake` profile includes media, calendar, weather, battery, devices, microphone/camera indicators, Dock badges, reminders, world clocks, timers, quick notes, a file shelf, image conversion and CI status. Add and configure them in the island's settings. Custom bar widgets can run alongside any island layout.

The root widget owns navigation, regions, hover, expansion and alerts. Override `widgets/lake/init.luau` and `lib/lake/attention.luau`, `policy.luau`, `motion.luau` or `slots.luau` to change those behaviors. The stock profile offers solid and translucent appearances, deduplicates stable alert IDs per component and temporarily selects a matching file component during a drag. An alert scheduling error appears in settings.

Integrations live in `lib/lake/services/`. Keep a component's lifecycle and service calls when replacing its views, or extend its stock definition with the [component API](/omnishell/reference/components-configuration/). Custom views can combine those integrations with their own data, actions, providers, shaders and animations.

- Media offers compact, peek and expanded views. Scrubbing sends a seek on release.
- Timers persist an absolute deadline. Each configured instance has its own timer and saved state. A visible running countdown reads the seconds feed; completion and save failures expose Retry. Timers cannot fire while OmniWM is stopped.
- Calendar alerts use the configured lead time. Battery and device alerts follow data changes.
- Reminders asks for access only through an explicit action. Its data includes up to 100 incomplete reminders, the total count and read/action errors. The stock view shows the first four and lets the user complete writable reminders.
- Badges shows raw Dock badge labels for apps with managed windows, even when the Workspace Bar is disabled. It supplies no notification contents or reply API.
- Quick note uses native multiline text input, explicit save and clipboard copy. Each configured instance has its own saved note.
- Shelf and converter views reuse the [file services](/omnishell/reference/resources-desktop/). Conversion also requires approval of its native program’s trust prompt; adding or enabling the component does not grant program trust.
- CI status requires a repository in its options. Its polling and request failures are handled by the component's service module.

Unavailable data and denied permissions have explicit UI states. Notification replies, call control and camera capture are outside these integrations; microphone/camera indicators report activity only.

See [Components and configuration](/omnishell/reference/components-configuration/) for extending a stock component while retaining its services. See [Providers](/omnishell/reference/providers/) before enabling a native integration process.

## Detachable widgets

For authored roots, `[island] sizing = "display"` fits the island to its display. `ctx.data.island.usableRect` supplies local safe bounds outside the menu bar, notch and reserved workspace-bar band. The native preview uses representative display bounds, and fixed surface-size controls are hidden for display sizing. Use a fixed `ui.stack` with stable keyed child wrappers and the existing `dx`/`dy` layout offsets. Keep each component under the same wrapper and parent while changing placement.

A handle can declare `gesture.track.mode = "move"` or `"resize"`, a strict ancestor `target` key, `bounds`, `min`, and `max`. Resize also declares `edge` (`n`, `ne`, `e`, `se`, `s`, `sw`, `w`, or `nw`). Samples stay native. The handler receives `selected`, `began`, release `ended`, and `applied` or `cancelled` boundary events. On release, render `event.rect` on the target and set `manipulationCommit = event.transaction`. Persist only after the matching `applied` receipt. A callback acknowledgement alone does not confirm placement.

### Move and scale

`gesture.track.mode = "scale"` scales proportionally from a corner. It requires `edge = "nw"`, `"ne"`, `"sw"` or `"se"`; single-edge scale handles are rejected. Move and scale also accept `inset = { x = ..., y = ... }`, with each fraction in 0–0.5, excluding 0.5. Insets describe the content inside the target envelope, so scaling fixes the opposite content corner and uses the content dimensions for drag gain. Insets are rejected for resize.

Declare `manipulationFollow = { response = 0.363, bounce = 0.42 }` on the keyed target, not on its handles. Response accepts 0.05–2.5 seconds; bounce accepts 0–0.95 and defaults to zero. A widget tree accepts up to 24 follow targets, and each one moves and settles on its own. Put the property on a component view's visible returned element, not on `ui.component`, which rejects it.

```lua
ui.stack {
    key = "card", w = 440, h = 570,
    manipulationFollow = { response = 0.363, bounce = 0.42 },
    ui.box {
        w = 24, h = 24, align = "bottomTrailing",
        gesture = {
            axis = "free", source = "pointer", threshold = 1,
            track = {
                mode = "scale", target = "card", edge = "se",
                inset = { x = 6.5 / 353, y = 0 },
            },
        },
    },
}
```

The release handler may render `event.rect` or any other rectangle, such as the card's home placement, with `manipulationCommit = event.transaction`. The target settles to that rendered rectangle, and the matching `applied` receipt reports it. Persistence still waits for `applied`. Outside an active manipulation, changing placement settles only in a render where `manipulationCommit` changes. This is separate from the existing release-rectangle acknowledgment described above.

### Decorative geometry and effects

Set `decorative = true` on liquid connectors, frames and preview geometry. Decorative subtrees cannot contain input or handlers and do not register pointer regions. Transparent canvas holes remain available to other applications while an already captured drag continues across them.

A stack's `effect = { source = "wave.metal", values = { 2 }, fps = 30, bleed = 8 }` processes its owned text, images, paths, masks and nested shader output with the existing Metal texture shader contract. Keep live material on an ancestor outside the effect stack. Nested group effects and backdrop materials within an effect are rejected. Native editing stays undistorted; Reduce Motion disables nonlinear effects. Effects follow the widget's geometric interaction bounds, rather than providing an inverse hit map for arbitrary shader code.

### Shared glass shapes

`ui.shape{ follow = "card" }` binds a decorative shape in a shared body to a keyed manipulation-follow target. While the target is dragged, scaled or settling, the shape is drawn, hit-tested and counted in island regions at the target's presented position and scale. The body itself is not scaled, so the shape's shadow, rim and blur keep their size. The corner radius scales with the shape by default (`followRadius = "scaled"`); `followRadius = "fixed"` keeps it in body units. Set `hit = false` on liquid details that should let the pointer through: the shape then adds no input coverage or island region. References resolve against the final expanded tree, so a shape may precede its target. [Shape tracks](/omnishell/reference/effects-shaders/#shape-track-wire-contract) cover shape reveal, edge springs, impulses and bound sources.
