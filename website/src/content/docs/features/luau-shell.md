---
title: OmniShell
description: Build Luau widgets, menus and Dynamic Islands, or configure desktop styles, bars, drawers and palettes.
sidebar:
  hidden: true
---

:::note[Unreleased]
OmniShell is available when building from `main` and is not included in v0.7.6. See [Building from Source](/developers/building/) for the separate Dev app.
:::

OmniShell is OmniWM’s editable Luau desktop shell. It draws the [workspace bar](/features/workspace-bar/), [Hidden Bar](/features/hidden-bar/) panels, popouts, edge drawers and Dynamic Islands. OmniWM supplies desktop data and native controls; your Luau code builds a tree with the `ui` DSL and decides how it looks and responds.

| Part | What it provides |
|---|---|
| Widget | A folder with `init.luau`; `render(ctx)` draws its bar slot or island root. |
| Popout | A widget’s `popout(ctx)` panel, opened from a click or command. |
| Drawer | A panel on a screen edge that combines widgets’ popouts. |
| Dynamic Island | A persistent surface whose root chooses compact and expanded content. |
| Component | A reusable package with a manifest, views, options and optional integrations, mounted by an island root. |
| Profile and palette | A profile supplies style, layout and sources; a palette changes its colors. |

## Start building

| Guide | What you will build |
|---|---|
| [Build your first widget](/omnishell/guides/first-widget/) | A clock with a declared setting and a place on the bar. |
| [Build a menu](/omnishell/guides/menus/) | A button, action rows, a submenu and an optional edge drawer. |
| [Build a Dynamic Island](/omnishell/guides/dynamic-island/) | A separate profile, expanding root and reusable clock component. |
| [Luau API reference](/omnishell/reference/) | Browse every shipped type and function by topic or name. |

## Configure it in Settings

The **Desktop** group in Settings gives the shell its own destinations. Search Settings to jump to a feature or control.

| Destination | What you can change |
|---|---|
| **Styles & Widgets** | Select a style to preview and edit it, choose **Use Style** to activate it, and select a **Palette** or wallpaper colors for the selected style. |
| **Styles & Widgets > Bar** | Arrange widgets, add them with **Add Widget…**, open their options, choose placement and display overrides, adjust the bar’s look, and manage app exclusions and icon overrides. |
| **Styles & Widgets > Island** | Preview compact and expanded states, choose displays and fullscreen behavior, and configure the selected style’s island. Lake exposes native widget, appearance, interaction, and placement editors. |
| **Styles & Widgets > Drawers** | Add drawers and configure their placement, hover, widgets and shortcut. |
| **Menu Bar** | Change OmniWM’s status item and configure the **Hidden Bar** tab. |
| **Network & Permissions** | Review installed widgets’ declared hosts, change remembered consent and program trust, and turn Weather or Lyrics off. Organization-managed blocks are locked. |

You can configure the bar and island while their enable switches are off. The switches are independent: either surface can run alone, or both can run together. A **style** is a profile that supplies layout, widgets, and appearance; a **palette** changes its colors. Browsing a style preview leaves your desktop unchanged until you choose **Use Style**. Style options save to the selected style, and saved choices stay with that style when you switch away and return.

The previews render the actual widget sources with sample data. System materials and motion are shown on the live desktop. Matrix Rain and Sakura Petals have named effect controls under **Styles & Widgets > Bar**.

For source customization, open **Settings > Advanced > Shell Development**, choose **Widget Source**, and select **Edit Widget Source…**. OmniWM opens a persistent copy in your external editor. **Open Shell Folder…** and the CLI remain available for creating widgets and profiles; Settings does not include a Luau editor.

## Configuration guides

- [Profiles and palettes](/omnishell/configuration/profiles-palettes/) explains the shell folder, styles, overrides and wallpaper colors.
- [Bars, popouts, and drawers](/omnishell/configuration/bars-drawers/) covers lanes, widget options and edge panels.
- [Islands and components](/omnishell/configuration/islands-components/) covers placement, Lake and System Focus Ribbon.
- [Development and troubleshooting](/omnishell/configuration/development/) covers source editing, reloads, diagnostics and permissions.

## Previous guide sections

The original guide has moved into focused pages. Existing links to its sections remain available here.

| Section | New page |
|---|---|
| <span id="the-shell-folder">The shell folder</span> | [Open section](/omnishell/configuration/profiles-palettes/#the-shell-folder) |
| <span id="shelltoml">shell.toml</span> | [Open section](/omnishell/configuration/profiles-palettes/#profile-settings) |
| <span id="persistent-island">Persistent island</span> | [Open section](/omnishell/configuration/islands-components/#enable-and-place-an-island) |
| <span id="writing-a-widget">Writing a widget</span> | [Open section](/omnishell/guides/first-widget/) |
| <span id="visual-options-for-custom-bar-widgets">Visual options for custom bar widgets</span> | [Open section](/omnishell/reference/components-configuration/) |
| <span id="data">Data</span> | [Open section](/omnishell/reference/context-data/) |
| <span id="reminders-data">Reminders data</span> | [Open section](/omnishell/reference/context-data/) |
| <span id="native-text-fields">Native text fields</span> | [Open section](/omnishell/reference/ui-elements/) |
| <span id="elements">Elements</span> | [Open section](/omnishell/reference/ui-elements/) |
| <span id="shaders">Shaders</span> | [Open section](/omnishell/reference/effects-shaders/) |
| <span id="editable-effects-library">Editable effects library</span> | [Open section](/omnishell/reference/effects-shaders/) |
| <span id="paths">Paths</span> | [Open section](/omnishell/reference/ui-elements/) |
| <span id="native-input-and-intent">Native input and intent</span> | [Open section](/omnishell/reference/input-motion/) |
| <span id="captured-gestures">Captured gestures</span> | [Open section](/omnishell/reference/input-motion/) |
| <span id="declared-keyboard-input-and-outside-presses">Declared keyboard input and outside presses</span> | [Open section](/omnishell/reference/input-motion/) |
| <span id="actions">Actions</span> | [Open section](/omnishell/reference/context-data/) |
| <span id="drawers">Drawers</span> | [Open section](/omnishell/configuration/bars-drawers/#drawers) |
| <span id="permissions">Permissions</span> | [Open section](/omnishell/configuration/development/#permissions) |
| <span id="composable-island-profiles">Composable island profiles</span> | [Open section](/omnishell/configuration/islands-components/#lake-and-configured-instances) |
| <span id="customize-the-lake-profile">Customize the Lake profile</span> | [Open section](/omnishell/configuration/islands-components/#customize-the-lake-profile) |
| <span id="catalog-and-configuration-actions">Catalog and configuration actions</span> | [Open section](/omnishell/reference/components-configuration/) |
| <span id="editable-lake-components">Editable Lake components</span> | [Open section](/omnishell/configuration/islands-components/#editable-lake-components) |
| <span id="replacing-views-while-retaining-integrations">Replacing views while retaining integrations</span> | [Open section](/omnishell/reference/components-configuration/) |
| <span id="component-images-and-shaders">Component images and shaders</span> | [Open section](/omnishell/reference/effects-shaders/) |
| <span id="timers-json-and-durable-state">Timers, JSON and durable state</span> | [Open section](/omnishell/reference/services/) |
| <span id="http-and-an-all-luau-ci-component">HTTP and an all-Luau CI component</span> | [Open section](/omnishell/reference/services/) |
| <span id="optional-component-providers">Optional component providers</span> | [Open section](/omnishell/reference/providers/) |
| <span id="files-and-desktop-services">Files and desktop services</span> | [Open section](/omnishell/reference/resources-desktop/) |
| <span id="provider-file-attachments">Provider file attachments</span> | [Open section](/omnishell/reference/providers/) |
| <span id="springs-element-transitions-and-native-dragging">Springs, element transitions and native dragging</span> | [Open section](/omnishell/reference/input-motion/) |
