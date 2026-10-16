---
title: Development and troubleshooting
description: Create and eject OmniShell widgets, use editor types, inspect errors, and understand permissions.
sidebar:
  order: 4
---

:::note[Unreleased]
OmniShell is available when building from `main`.
:::

OmniShell scripts are ordinary files under `~/.config/omniwm/shell/`. Edit them in your own editor. The host watches source and configuration changes and reloads affected packages; you do not need to restart the window manager for each edit.

## Create or eject a widget

Create a new user widget:

```sh
omniwmctl shell init hello-clock
```

This creates `~/.config/omniwm/shell/widgets/hello-clock/init.luau`. Names use letters, digits, `-` and `_`. An existing folder returns `no_change` and is left intact. Follow [Build your first widget](/omnishell/guides/first-widget/) for a complete example.

Before changing an inherited widget, choose **Settings > Advanced > Shell Development > Widget Source > Edit Widget Source…**, or copy it into the persistent user layer:

```sh
omniwmctl shell eject clock
```

The effective widget is copied into `shell/widgets/clock/`. A widget already there returns `no_change`. **Open Shell Folder…** opens the containing folder. Settings does not include a Luau editor.

User widgets override all profiles, so use a unique name for a tutorial or a profile-local widget when a change should apply to only one style. The [shell folder and profile rules](/omnishell/configuration/profiles-palettes/#the-shell-folder) describe managed files, backup copies and fallback resolution.

## Modules and editor types

`omniwm.d.luau` in the shell folder provides the shipped type declarations for your Luau editor. The [browsable API reference](/omnishell/reference/) presents those declarations with examples and topic links.

Use `require("./helpers")` or `require("@self/helpers")` for a widget’s helper files. `require("../lib/panel")` loads a shared `lib/panel.luau`, from the top-level shell folder first, then the selected profile, then `default/`. Component libraries use the root profile’s overrides. Ordinary widgets can load up to 64 source files; island roots can load up to 512 including components and libraries. Exceeding the limit reports a load error.

`ctx.state` lasts across renders of one placement/display instance. Component `instance.state` is shared across that configured instance’s displays. Neither is saved automatically. Use [durable storage](/omnishell/reference/services/) for data that must survive reload or restart.

## Save and inspect changes

1. Add the widget in **Settings > Workspace Bar > Layout > Bar Widgets**, or configure it as an island root or component. A source file alone does not place it on a surface.
2. Enable the bar or Dynamic Island to run its live instances. Settings previews use sample data and do not run live integrations or commands.
3. Save a source, manifest or configuration edit. Check its rendered output and diagnostic state after the reload.
4. When testing a custom `trigger(ctx, event)` hook, run `omniwmctl shell trigger hello-clock refresh`. The hook receives the name and optional value; it runs on each displayed instance. A widget without the hook returns `not_found`.

See [Input and motion](/omnishell/reference/input-motion/) for root lifecycle events and [Components and configuration](/omnishell/reference/components-configuration/) for component lifecycle hooks. Editing source replaces its package; keep durable state separate from presentation state.

## Diagnostics

```sh
omniwmctl query shell-widgets
```

The query shows widget state and errors, plus mistakes in `shell.toml` and theme files such as unknown keys and invalid values. Use it after creating a package, changing placement, editing options or saving source. The Widgets library also shows effective source, placements and diagnostics.

`omniwm.log(...)` writes to the macOS unified log under the `shell` category. Inspect recent entries in Terminal:

```sh
/usr/bin/log show --last 10m --predicate 'process == "OmniWM" AND category == "shell"'
```

| Symptom | Check |
|---|---|
| Widget does not appear | Confirm its name is in a bar lane or the active island configuration, the owning surface is enabled, and the effective source is the file you edited. |
| An edit reports a compile or load error | Read the query diagnostic and correct the indicated source or manifest. A bad reload can leave the previous accepted widget running. |
| Widget stops after repeated errors | Correct the reported runtime error and save its source; repeated failures cut off that package. |
| Options are absent | Put `settings.toml` beside the effective `init.luau`; declare the keys that source actually reads. User replacements do not inherit an ignored schema. |
| State disappears after reload | Save durable values with `omniwm.store`; ordinary view state is not persisted. |
| Data is unavailable | Check the permission below, then the data or service error. Reading data alone does not grant access. |
| Provider does not run | Declare its manifest capability and explicitly enable `provider = true` in your own configured instance; see [Providers](/omnishell/reference/providers/). |

## Permissions

| Feature | Permission |
|---|---|
| Per-app volume | System Audio Recording, asked the first time an app is turned down |
| Calendar | Calendar full access, asked from the calendar widget |
| Reminders | Reminders full access, requested only by `reminders authorize`; independent of Calendar access |
| Wi-Fi network name | Location, asked from the Wi-Fi widget; signal, band and security need none |
| Bluetooth | Bluetooth, asked from the Bluetooth widget |
| Audio spectrum | System Audio Recording, like per-app volume |
| Log out, restart and shut down | Automation of loginwindow, asked the first time |
| Wallpaper theme | None; with Screen Recording already allowed, live and dynamic wallpapers are read as shown |

Now Playing needs no permission.

Component capabilities are separate from macOS permissions. Network hosts, files, clipboard and provider execution must satisfy the [component contract](/omnishell/reference/components-configuration/), [service API](/omnishell/reference/services/) and [provider policy](/omnishell/reference/providers/). A widget cannot grant itself new capabilities through its configuration controls.
