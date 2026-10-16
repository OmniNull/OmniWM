---
title: Islands and components
description: Configure persistent Dynamic Islands, Lake component instances, placement, and editable integrations.
sidebar:
  order: 3
---

:::note[Unreleased]
OmniShell is available when building from `main`.
:::

A Dynamic Island is a persistent surface whose root widget chooses compact, preview and expanded content. Components provide reusable views and integrations inside that root. Follow [Build a Dynamic Island](/omnishell/guides/dynamic-island/) to create a separate profile and your first component.

## Enable and place an island

Choose **Lake** or **System** in **Settings > Styles**, then open **Settings > Dynamic Island**. Selecting a style changes the shared profile for the bar and island without changing either enable switch.

Lake’s **Widgets** tab provides **Add Widget…**, per-instance enable switches, **Move**, **Remove**, and **Options…**. The native options editor assigns an instance to Automatic, Main, Side, or Expanded Only placement and exposes its declared options. **Appearance** controls the island’s shape and colors; **Interaction** controls click, right-click, hover, and swipe behavior, with motion tuning under **Advanced Motion**. **Placement** chooses displays, native fullscreen behavior, and advanced surface dimensions.

System’s Focus Ribbon builds its content automatically from the active workspace and focused window. Its Widgets tab explains that behavior; it does not use Lake’s component catalog. Both islands can be configured while disabled and run without the Workspace Bar. The native settings file stores the master switch as `[island] enabled = true`; placement belongs to the selected shell profile:

```toml
# In a profile folder's shell.toml:
[island]
root = "my-island"
displays = "notch"
width = 760
height = 300
fullscreen = "hide"
```

In the user shell file, use `[profiles.<profile>.island]` instead. An absent island table places no island. `root` defaults to `lake`; that widget must exist in a configured widgets folder. `displays` accepts `notch`, `main`, or `all`. `fullscreen` accepts `hide` (default) or `show`. Width and height are the fixed panel envelope in points, from 1 to 8192, clamped to each display. Change the Luau tree's size to expand or collapse its contents; the window does not resize with those transitions.

## Root geometry and display data

The root's `render(ctx)` receives `ctx.data.island`. It is `nil` in ordinary bar instances. It contains `display`, `size = {w, h}`, optional `notch = {x, w, h}`, `menuBar`, `scale`, `main`, `visible`, `fullscreen`, and `focused`. Coordinates start at the envelope's top left. `focused` reflects the island’s native keyboard focus lease. A focusable element can acquire it by clicking, and blur, a declared Escape key or an outside press releases it. A root can also appear in a bar lane, using a separate `ctx.state` for each placement and display.

`island.navigation` describes that display’s active workspace: `workspace` is its stable name, `name` its display label, `layout` is `niri` or `dwindle`, and optional `focused` is the selected managed window’s opaque ID. `windows` contains one entry per window with `id`, `bundle`, `name`, `title`, and `column` (one-based Niri column, or zero outside the Niri tree). Entries follow Niri column and row order, with floating windows after tiled windows. Titles use existing cached metadata and may be empty; use the app name as a fallback. Pass an ID to `omniwm.run("window focus " .. id)` to focus it. This data follows workspace and managed-selection changes without polling or per-frame Luau updates.

The island survives opening a popout or drawer and disabling the Workspace Bar. A hidden fullscreen island keeps its Luau instance and state, suspends rendering, and resumes with current data when shown. Its view-only data demand is suspended too. See the [Luau API reference](/omnishell/reference/) for components, timers, durable state, providers, motion, text entry, file resources and desktop services.

## Pointer handling

Transparent-window click-through still needs a live check on the target macOS system. OmniWM's own mouse handling uses cached visible/actionable rectangles, preserving gaps between capsules; these rectangles conservatively cover rounded corners and path holes.

## System Focus Ribbon

System also includes **Focus Ribbon**. Turn on **Settings > Dynamic Island > Enable Dynamic Island** to show its compact black island at the top of each display. Navigating Niri windows or switching workspaces expands the same island into a ribbon of that workspace’s window icons, in column order. Short ribbons stay centred; longer ribbons follow the focused window within the list’s edges. Each window has its own icon, including multiple windows from one app, with the focused window’s title beneath the ribbon or its app name when no title is available. The ribbon stays open while the pointer is inside and otherwise collapses 2.6 seconds after the last navigation or pointer exit; click the compact island to reopen it, click an icon to focus that window, or click outside to collapse. It does not take keyboard focus. The island hides in native fullscreen and works when the workspace bar is disabled.

## Lake and configured instances

The bundled `lake` profile draws its island in editable Luau. Its bar lanes remain independently configurable: custom bar widgets and an island can run together. The native **Island** switch controls whether the island is present; selecting a profile does not turn it on. The profile uses a short hover dwell to show a preview, a click to expand, native button press feedback, an upward pointer/trackpad gesture to collapse, and outside press or Escape to dismiss. The primary capsule accepts keyboard focus on click in compact, preview and expanded modes. While focused, Left and Right cycle enabled components in configured order; Escape dismisses the expanded content and releases focus. Collapsing with a click or gesture may leave the compact capsule focused until Escape, blur or an outside press.

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

The native **Settings > Dynamic Island** editors provide the same declared widget options and profile controls without requiring the island to be enabled. Use **Advanced Motion** for native motion tuning and **Placement** for display scope and surface dimensions.

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
- Shelf and converter views reuse the [file services](/omnishell/reference/resources-desktop/). Conversion also requires a hand-edited `provider = true` on the configured instance; adding the component in settings does not grant permission to run its provider.
- CI status requires a repository in its options. Its polling and request failures are handled by the component's service module.

Unavailable data and denied permissions have explicit UI states. Notification replies, call control and camera capture are outside these integrations; microphone/camera indicators report activity only.

See [Components and configuration](/omnishell/reference/components-configuration/) for extending a stock component while retaining its services. See [Providers](/omnishell/reference/providers/) before enabling a native integration process.
