# Lefty

Workspaces on the left, your macOS menu bar on the right.

## Previews

![Workspaces on the left, with the cover matched to the wallpaper](previews/left.png)

Shown with the cover matched to the wallpaper and the native palette. By default the cover is the palette's surface colour.

## What it changes

A half-width bar in the menu bar's left corner. Workspaces are numbered circles, and the focused one becomes a filled blue pill. The macOS menu bar items on the right stay as they are. The bar hides the current app's menus and adds an Apple button and an app button that open them. Popouts have rounded panels with a faint glow along the bottom edge. The palette follows the system's light and dark appearance.

## Controls and commands

Change these in `shell.toml`, under your profile:

```toml
[profiles.lefty.widgets.workspaces]
cover = "#0C1733"   # surface, background, elevatedSurface or a #RRGGBB colour
coverWidth = 600    # the bar's width in points, minus 8
```

- A transparent bar would show the app menus through the workspaces, so the cover is opaque. For a transparent look, set it to a colour close to your wallpaper's top edge. It is one fixed colour, so this suits a still wallpaper.
- `coverWidth` hides app menus up to that width. Keep it short of the notch: macOS may move menu bar icons to the left of the notch, and they need that gap to stay visible and clickable.
- The default fits a 33 pt menu bar. On a display with a different one, set `yOffset` to the menu bar's height minus 32.
- Keep workspaces as the bar's only widget. Others would not be covered.

## Credits and licences

Style code is GPL-2.0-only, as declared in [style.toml](style.toml). The look module follows the structure of OmniWM's Sakura style, (C) 2026 OmniNull, GPL-2.0-only. No fonts are bundled; text uses the system font.
