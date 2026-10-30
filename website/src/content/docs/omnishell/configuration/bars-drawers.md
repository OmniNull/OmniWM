---
title: Bars, popouts, and drawers
description: Arrange OmniShell bar lanes, configure widget options, and reuse popouts in edge drawers.
sidebar:
  order: 2
---

Bar widgets and popouts use the same widget package. `render(ctx)` supplies the bar slot; `popout(ctx)` supplies its panel. A drawer combines several widgets’ popouts at a display edge. Start with [Build your first widget](/omnishell/guides/first-widget/) or [Build a menu](/omnishell/guides/menus/) to create one.

## Bar lanes

`leading`, `center` and `trailing` are the bar's three groups, in order; widgets in a split bar's active island come from `leading` and `center`. With **Full Width** on, the bar spans the screen edge and the groups sit at its start, center and end; **Notch Mode** then picks where `center` goes on a notched display.

An enabled full-width bar requests macOS menu-bar auto-hide unless its position is **Below Menu Bar** (**Unreleased:** this exception is available when building from `main`). Moving the last requesting bar below the menu bar, disabling it or quitting OmniWM normally restores the previous preference if it still matches the value OmniWM applied. Another display's full-width bar can keep automatic hiding active because the preference is system-wide. See [Full Width](/features/workspace-bar/#layout-and-appearance-options) for manual hiding and crash recovery. At overlapping top placement, the bar stays above the native menu bar. The themed presets reserve their occupied space for tiled windows; **Reserve Space for Workspace Bar** controls this, and an automatically hidden workspace bar does not reserve space.

**Settings > Styles & Widgets > Bar** edits them for the selected style: drag to reorder, select **Add Widget…** to choose a group, and select a widget for its options or **Remove from Bar**. **Use Style Layout…** restores all three groups together. Right-click a widget on the bar to move it, take it off the bar or open these settings; when the widget uses right-click itself, Option + right-click opens the same menu. Your own widgets in `widgets/` are listed there to add.

```toml
# In ~/.config/omniwm/shell/shell.toml, for the default profile:
profiles.default.leading = ["omniwm", "workspaces", "scratchpads"]
profiles.default.center = ["clock"]
profiles.default.trailing = ["volume", "system-stats"]
```

Use the active profile’s name instead of `default`. In that profile folder’s own `shell.toml`, omit `profiles.<name>.`. Profile settings and precedence are explained in [Profiles and palettes](/omnishell/configuration/profiles-palettes/#profile-settings).

## Widget options

**Add Widget…** also offers `launcher`, `active-window`, `input-source`, `wifi`, `bluetooth`, `battery-details`, `world-clock`, `privacy` and `control-center`. With **Transparent Background** and **Show Item Backgrounds** both on, the default widgets draw their own capsules and palette popouts.

Select a widget to change supported choices visually. Options follow the actual widget implementation in the selected style; a style that does not use an option does not show it. World Clock provides a location list, and Weather provides city or coordinates, units, and refresh interval. The default widgets also read these values from `profiles.<profile>.widgets.<name>` in `shell.toml`:

| Widget | Settings |
|---|---|
| `workspaces` | `indicator`: `"pills"`, `"underline"`, `"dots"`, `"numbers"` or `"minimal"` |
| `stats` | `variant`: `"meters"`, `"gauge"` or `"graph"` |
| `world-clock` | `zones`: a list of `{ label = "Tokyo", zone = "Asia/Tokyo" }`; `bar`: how many to show on the bar |
| `launcher` | `mode`: a command palette mode such as `"windows"`; `symbol`: an SF Symbol |
| `active-window` | `display`: `"icon_and_text"`, `"icon_only"` or `"text_only"`; `maxWidth` |
| `battery-details` | `percent`: `"beside"`, `"inside"` or `"off"` |
| `control-center` | `tab`: the tab it opens on |

`hiddenBarWidget` and `systemStatsWidget` name the widgets that draw the Hidden Bar drawer and the System Stats popout. The profile supplies defaults; GUI changes are saved as that profile’s overrides. Workspace Bar’s master enable switch, excluded apps and icon overrides stay global. Enabling **System Stats Button** also places the configured stats widget on the bar if it was removed.

For your own widgets, place `settings.toml` beside the effective `init.luau` to declare **Options** controls. Values arrive in `ctx.data.settings`. See the [widget tutorial](/omnishell/guides/first-widget/) and [settings schema reference](/omnishell/reference/components-configuration/).

## Popouts

An element with `onClick = ui.popout` opens its widget’s `popout(ctx)`. You can also use `popout = true`, or run `omniwmctl shell toggle <widget>`. On the focused display, the panel opens beneath the bar slot; a widget with no visible slot uses the top-right edge. Only one popout or drawer is open at a time.

Use stable element keys for interactive controls. The [UI elements](/omnishell/reference/ui-elements/) and [input reference](/omnishell/reference/input-motion/) describe callbacks and native controls. The [menu tutorial](/omnishell/guides/menus/) builds a popout with action rows and a submenu.

## Drawers

Configure drawers under **Settings > Styles & Widgets > Drawers**: add a drawer, choose its edge and widgets, arrange them, and adjust hover, close, hover area, and background behavior. **Configure Shortcut…** opens the registered Toggle action; enable the bar or island first if the drawer has not been loaded.

A `[drawer.<id>]` stacks the popouts of its widgets in one panel on a screen edge, like a control center. Open it with `shell toggle <id>`, from a click, with **Settings > Keyboard Shortcuts > Toggle \<id\>**, or by moving the pointer to that edge when `hover = true`. Only one drawer or popout is open at a time. `width = 900` limits the hover to that stretch of the edge's middle, and `reach = 10` lets the pointer open it from up to 10 points away from the edge. `close = "leave"` closes it as soon as the pointer leaves it; opened by a click or hotkey, it stays until the pointer has been inside and left. `chrome = false` drops the panel's own background, padding and slide, so the widget draws the whole panel flush against the edge, beside the bar, with room to overshoot.

```toml
# In ~/.config/omniwm/shell/shell.toml:
[profiles.default.drawer.controls]
edge = "right"
widgets = ["volume", "media", "calendar"]
hover = true
```

In a profile folder’s `shell.toml`, use `[drawer.controls]`. A drawer widget supplies `popout(ctx)`, so the same custom menu can run as a bar popout and inside a drawer without a second implementation. Use distinct drawer and widget names: `shell toggle` resolves a matching drawer first.

## Hidden Bar menus

Hidden Bar app menus use the `hidden-bar-menu` widget, which opens beneath the clicked icon while the icon strip stays visible. Its `ctx.data.hiddenBar.menu` contains the current menu's `title`, optional `backID`, and `rows` with `id`, `title`, `enabled`, `mark`, `shortcut`, `submenu`, and `separator`. The widget sends `hidden-bar-menu <id>` to enter a submenu, go back, or execute a command. IDs are valid only for the displayed page. OmniWM temporarily exposes the selected native status item while acquiring and using its menu, then conceals it again when the menu ends. Like other widgets, its appearance can be customized in the selected profile’s `widgets/hidden-bar-menu/init.luau`.

`ctx.data.hiddenBar.items` stays current while the drawer is closed, so a bar widget can put hidden apps inline, beside the system controls:

```luau
-- In ~/.config/omniwm/shell/widgets/menu-extras/init.luau:
function render(ctx: Context)
    local row = { gap = 2 }
    for _, item in ipairs(ctx.data.hiddenBar.items) do
        row[#row + 1] = ui.stack{ key = item.id, w = math.ceil(item.w) + 8, h = 22, help = item.name,
            onClick = "hidden-bar activate " .. item.id,
            if item.image then ui.image{ image = item.image, w = item.w, h = item.h }
            else ui.symbol{ name = "app.dashed", w = 16, h = 16 } }
    end
    return ui.row(row)
end
```

See [Hidden Bar](/features/hidden-bar/) for concealment setup and Full Disk Access requirements, and the [context and data reference](/omnishell/reference/context-data/) for menu field types.
