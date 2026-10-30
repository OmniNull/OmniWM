---
title: Profiles and palettes
description: Choose an OmniShell style, understand profile overrides, and customize palette and wallpaper colors.
sidebar:
  order: 1
---

**Unreleased: OmniShell is available when building from `main` and is not included in v0.7.6.** See [Building from Source](/developers/building/).

A **profile** supplies the widgets, libraries, layout and appearance for a desktop style. A **palette** changes its colors. Select a style in **Settings > Styles & Widgets**, then choose **Use Style**. Browsing previews leaves the desktop unchanged until you apply one. The bar and island enable switches remain independent. Saved choices stay with their profile when you switch away and return.

## The shell folder

```
~/.config/omniwm/shell/
├── shell.toml          # chooses the profile, holds your settings for each one
├── omniwm.d.luau       # type definitions for your editor
├── widgets/            # your widgets, used before any profile's
├── default/            # managed by OmniWM
├── wayline/            # bundled styles, also managed by OmniWM
├── nocturne/
├── lake/
├── celestial/
├── matrix/
├── sakura/
└── <profile>/          # your own profiles
```

`default/` holds the bundled widgets and themes, and OmniWM updates it with each release. If you edit a managed file, the next update keeps your copy beside it as `<file>.edited-<date>`. **Settings > Advanced > Shell Development > Edit Widget Source…** or `omniwmctl shell eject <widget>` creates an editable copy before you customize an inherited widget. For an OmniWM-managed profile, the copy goes into top-level `widgets/`; for your own profile, it goes into `<profile>/widgets/`. Top-level user overrides take precedence over the selected profile; widgets in your own profiles are left alone.

`omniwmctl shell init <widget>` creates `<profile>/widgets/<widget>/init.luau` in the selected profile, including `default/` when that profile is selected. It leaves an existing destination folder intact. To make a widget an override for every profile, place its folder in top-level `widgets/`.

A profile is any other folder in the shell folder. Choose it in **Settings > Styles & Widgets** with **Use Style**, with `profile = "<name>"` in `shell.toml`, or with `omniwmctl shell profile <name>`. The **Palette** picker recolors the selected style and `omniwmctl shell theme <name>` the active profile, and that profile keeps the choice. Anything a profile does not contain comes from `default/`.

The bundled styles are profiles that restyle the whole bar and its popouts, on the same data and commands as the default widgets. **wayline** has a 40 pt bar with coloured icon blocks, **nocturne** has 40 pt capsules and panels that hang from the bar, and **celestial** follows Caelestia: a 60 pt bar with shaped workspaces and a status pill, and a dashboard that drops from the top centre on hover with Dashboard, Media, Performance and Weather tabs. Celestial starts on the left; all styles support top, bottom, left and right placement, and their bar contents scale with the thickness setting. OmniWM updates them like `default/`. A folder you made under one of these names is left alone, and the style is not installed.

**matrix** is Rain Terminal: a dark green, monospace style with a continuous falling-code shader behind the full-width bar, compact numbered workspaces and matching square popouts. Choose **Matrix** in **Settings > Styles & Widgets**, then **Use Style** or run `omniwmctl shell profile matrix`. Its palette stays dark in both system appearances. Widgets retain their ordinary controls, including media transport, volume, calendar, weather and system details.

**sakura** is Sakura Glass: warm ivory, rose accents, rounded cards and gently falling cherry-blossom petals. The shader stays inside the bar and matching popouts, leaving the desktop and app windows clear. Choose **Sakura** in **Settings > Styles & Widgets**, then **Use Style** or run `omniwmctl shell profile sakura`. Its palette stays light in both system appearances, and its widgets keep the usual media, audio, calendar, weather and system controls.

## Profile settings

```toml
profile = "default"
profiles.default.theme = "nocturne"          # a bundled theme or themes/<name>.toml
profiles.default.leading = ["omniwm", "workspaces", "scratchpads"]
profiles.default.center = ["clock"]
profiles.default.trailing = ["volume", "system-stats"]

[weather]
city = "Toronto"                   # or latitude = 43.65, longitude = -79.38
units = "celsius"                  # or "fahrenheit"
refresh = 15                       # minutes, at least 5

[profiles.default.widgets.volume]
step = 5                           # any keys: the widget reads them as ctx.data.settings
interval = 2                       # seconds between timed updates for this widget

[profiles.default.drawer.controls]
edge = "right"                     # left, right, top or bottom
widgets = ["volume", "media", "calendar"]
hover = true                       # open when the pointer reaches the edge

[profiles.default.workspaceBar]
height = 40                        # also editable in Styles & Widgets

[profiles.default.hiddenBar]
enabled = true                     # also rehideIntervalSeconds
```

Everything except `profile` and `[weather]` belongs to one profile, under `profiles.<name>`, so changing one profile never changes another. A profile folder's own `shell.toml` takes the same keys without the prefix, and your `profiles.<name>` settings win over it. Style options in **Settings > Styles & Widgets** save to the selected style. Both dotted keys and TOML tables are supported. Display-specific choices are saved in `profiles.<name>.monitorBarOverrides`; they override that profile’s general bar settings. Resetting a control restores the profile default without changing another profile.

The bar lane, widget and drawer keys are described in [Bars, popouts, and drawers](/omnishell/configuration/bars-drawers/). Island roots and component instances are described in [Islands and components](/omnishell/configuration/islands-components/).

## Palettes and wallpaper colors

OmniWM bundles the themes catppuccin, celestial, dracula, everforest, gruvbox, kanagawa, matrix, monolith, nocturne, nord, rose-pine, sakura, tokyo-night and wayline, each with light and dark colours.

A theme in `themes/<name>.toml` sets palette roles under `[light]` and `[dark]` (for example `accent = "#FF9500"`) and may set the bar's look under its own `[workspaceBar]`.

### Wallpaper palette

`theme = "wallpaper"` makes the palette from the main display's wallpaper, Material 3 style, and `scheme` picks how: `tonalSpot` (the default), `content`, `vibrant`, `expressive`, `fidelity`, `fruitSalad`, `rainbow`, `neutral` or `monochrome`; **Settings > Styles & Widgets > Palette** and `omniwmctl shell theme wallpaper <scheme>` set both. OmniWM writes it to `themes/wallpaper.toml` and makes it again when the wallpaper, the Space or the displays change. Live wallpaper apps that draw at the desktop level, like [Pixeldish](https://github.com/dappermint/pixeldish), are read from what they show on screen, so the palette follows them on the next Space or display change.

### Palette roles and bar fill

Besides the base roles, the palette has Material 3 style `highestSurface`, `accentContainer`, `secondaryAccent`, `secondaryContainer`, `tertiaryAccent` and `tertiaryContainer`, each container with a `…Foreground` for text on it; a theme that leaves them out gets readable ones made from its own accent and surfaces.

`shell.toml`'s `[workspaceBar]` wins over the theme's. There, `barFill = "surface"` paints the bar with a palette role instead of its Settings background, and `barBorder = "border"` adds a 1 pt edge to that fill; add `/0.8` to a role for 80% opacity.

**Custom Accent Color** and **Custom Text Color** work with every palette. Resetting a color restores the palette value. The native material and motion appear on the live desktop; Settings previews use the actual widget sources with sample data.

Matrix Rain and Sakura Petals expose named effect controls under **Styles & Widgets > Bar**. To make your own effects, see [Effects and shaders](/omnishell/reference/effects-shaders/).

Use [development diagnostics](/omnishell/configuration/development/#diagnostics) to find unknown keys, invalid values and theme errors.
