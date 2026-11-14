---
title: Wallpaper
description: Give each display its own folder of wallpapers, shuffle and rotate them, and color OmniWM from the wallpaper at the moment it changes.
sidebar:
  order: 9
---

**Unreleased.** Available when building from `main`.

OmniWM can manage your wallpapers: each display shows wallpapers from a folder, in a shuffled order that shows every wallpaper once before any repeats, and can change on a schedule. When the wallpaper on the main display changes, the wallpaper palette changes at the same moment, so the bar, island and popouts never show the colors of the previous wallpaper.

The feature is off by default. Until you turn it on, OmniWM never sets a wallpaper and adds nothing to `settings.toml`.

## Turn it on

Open **Settings > Wallpaper** and turn on **Manage Wallpapers**. OmniWM uses `~/Pictures/Wallpapers` for every display until you choose another folder.

- **Folders** lists every connected display, and displays you set a folder for that are not connected now. Each has **Choose…**, which opens the standard folder panel, and **Reset to Default**, and shows how many wallpapers its folder holds. **Default Folder** is the folder for every display without its own.
- **Rotation** sets **Change Wallpaper** to **Off**, every 15 or 30 minutes, every hour, or **Custom** (1 to 1440 minutes). It stays **Off** until you choose an interval, so turning the feature on changes nothing by itself. **Next Change** shows the time of the next change in 24-hour time. The time is kept across restarts, so quitting OmniWM does not postpone it.
- **Placement** chooses **Fill Screen**, which crops the wallpaper to the display, or **Fit to Screen**.
- **Next Wallpaper on All Displays** moves every display to its next wallpaper.

A wallpaper is a JPEG, PNG, HEIC, HEIF, WebP, TIFF, GIF or BMP file directly inside the folder. Hidden files, other files and subfolders are left out. The folder is read again whenever you use it (**Next**, picking a wallpaper, a rotation, a folder change, or opening the picker or this page), so wallpapers you add or remove are picked up without a restart; switching Spaces or connecting a display does not read it again. A folder that can't be read says so, with the reason, instead of showing as empty.

OmniWM keeps each display's place in its shuffle and the time of the next change in `wallpaper-state.json` beside its other state. If that file can't be saved, **Settings > Wallpaper** and the popout say so; the wallpapers still change.

Reading macOS's wallpaper settings, listing folders and checking files happen in the background, never on the main thread. Turning **Manage Wallpapers** off stops all of it: no observers, timers, reads or previews run until you turn it on again.

### Displays

Displays are found as they connect: a MacBook alone, a MacBook with external displays, a closed MacBook with an external display, and two identical monitors all work. OmniWM tells displays apart by their display UUID, never by their name alone, so two monitors of the same model keep their own folders and shuffle orders, and a wallpaper is never applied to the wrong one when the other is unplugged. When a display disconnects in the middle of a rotation, the remaining displays change as usual and the disconnected display keeps its place in its shuffle for when it returns.

## Colors

**Colors** turns on **Match Colors to Wallpaper**, the same Wallpaper Colors palette as **Settings > Styles & Widgets > Palette**, and picks its Material 3 scheme. While **Manage Wallpapers** is on, each scheme shows a live preview made in the background from the main display's current wallpaper; choosing one recolors OmniWM immediately. If the colors can't be written, OmniWM says why. The scheme is the existing `scheme` setting in `shell.toml`, so it applies to everyone who uses the wallpaper palette, with or without the wallpaper manager.

When OmniWM changes the main display's wallpaper, it makes the palette from the whole wallpaper file, applies it, and then sets the wallpaper, so the colors and the wallpaper change together. The palette comes from the whole file the same way OmniWM reads any still wallpaper, so a wallpaper gets the same colors on every display and with Fill or Fit. The palette for the next wallpaper in the shuffle is prepared ahead of time. Wallpapers you set elsewhere, such as in System Settings, are still followed the way the [wallpaper palette](/omnishell/configuration/profiles-palettes/#wallpaper-palette) always has.

## Window border

In **Settings > Appearance > Borders**, **Follow Wallpaper Colors** colors the focused window's border with the accent the bar draws with, in light and dark, including a bar accent color you set. With Wallpaper Colors it changes in the same moment as the bar. With the bar and island off it uses the border's own colors. A gradient border runs from the accent to the tertiary accent, and a glow uses the accent. It works with any OmniWM palette and is off by default. A border width of 2 px gives a thinner look.

## Bar widget and popout

Add **Wallpaper** to a bar lane in **Settings > Styles & Widgets**. The bar shows a plain wallpaper glyph; click it for the popout:

- The rotation chip shows the interval and the next change. Click it to step through every 15, 30 or 60 minutes and off. While **Manage Wallpapers** is off it changes nothing.
- **Next all** (or **Next both** with two displays) moves every display on.
- One card per display, drawn at that display's shape, shows its current wallpaper with its own **Next**.
- The palette strip shows the colors in use, and one chip per scheme with its swatches. Click a chip to recolor OmniWM with that scheme.
- With more than one display, tabs choose which display's wallpapers the grid shows. The current one is marked **Now**; click any wallpaper to set it. **Show all** pages through the whole folder, and the page stays as you left it when you close and reopen the popout.
- **Change folder** chooses that display's folder, and **Open folder** opens it in Finder.

Previews are made in the background, cropped to each display's shape, only while the popout or the island's expanded view is open, and only for the wallpapers on screen. The bar glyph and the island's compact view make none.

## Island

With the [Lake](/omnishell/configuration/islands-components/#lake-and-configured-instances) style, add **Wallpaper** from the island's **Add Widget…** catalog. Its compact view shows the main display's wallpaper name, and its expanded view is the full popout.

## Widgets and automation

Custom widgets read [`ctx.data.wallpaper`](/omnishell/reference/context-data/#wallpaper-snapshots), and `ctx.data.wallpaperPreviews` where they draw previews, and use the [`wallpaper` actions](/omnishell/reference/context-data/#actions) with `omniwm.run`, for example `omniwm.run("wallpaper next all")`. The settings are described in [`wallpaper`](/config/settings-reference/#wallpaper).
