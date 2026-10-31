# Vitreus

Liquid glass with a Desk for focus sessions and tasks.

## Previews

Previews will be added with the Settings gallery.

## What it changes

Liquid glass in Island, Frame and Notches layouts, with calendar, controls and player panels, a Desk, a top shelf, docks and an optional audio visualiser. Its own palette stays dark; **Wallpaper Colors** tints the glass and text from the wallpaper.

## Controls and commands

Turn on **Settings > Styles & Widgets > Island > Show Dynamic Island**. Open the Desk with the button at the end of the bar; drag its top grip to move it, or a corner to shrink it to half size. Drop it near home, or click the grip there, to return it. Closing it also returns it home.

In the Island layout, drag a panel or section grip to pull it out. Release near its home to redock, near a screen edge to stick, or over the top shelf to store it. Drag to the top edge to open the shelf during a move. Click the owning clock, controls button or window title to return its panel and sections. The media card appears when music is available. The audio visualiser is off by default.

Optional commands: `omniwmctl shell trigger vitreus desk <display-id>` toggles the Desk on a display; obtain its ID with `omniwmctl query displays`. **Settings > Keyboard Shortcuts > Toggle vitreus** (unbound by default) toggles it on the focused display. `omniwmctl shell trigger vitreus desk-close` closes every Desk.

## Credits and licences

Style code is GPL-2.0-only, as declared in [style.toml](style.toml). Adapts [Vitreus](https://github.com/natepayn3/Vitreus) (MIT); retain [Vitreus-LICENSE.txt](Vitreus-LICENSE.txt). Space Grotesk is supplied under the SIL Open Font License; retain [fonts/OFL.txt](fonts/OFL.txt).
