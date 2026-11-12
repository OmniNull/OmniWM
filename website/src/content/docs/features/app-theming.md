---
title: App Theming
description: Color Ghostty, kitty, herdr, Neovim and your own templates from OmniWM's palette, in light and dark, the moment the palette changes.
sidebar:
  order: 9
---

App theming writes OmniWM's palette into other apps' theme files and asks those apps to reload. It works with every OmniWM palette: the native colors, a bundled or custom [theme](/omnishell/configuration/profiles-palettes/#palettes-and-wallpaper-colors), and the wallpaper palette. With the bar and island turned off, it uses the theme your shell configuration selects. Open **Settings → App Theming**. Nothing is on until you turn it on.

When the palette changes, or macOS switches between light and dark, OmniWM renders every app you turned on straight away. A file is only written when its contents change, each write replaces the file in one step, and one app failing never stops the others. Each app's row shows the files it writes, how it reloads, and the result of the last update.

## Ghostty

Turning on **Ghostty** writes two themes, `omniwm-light` and `omniwm-dark`, to `~/.config/ghostty/themes/`. Select them in your Ghostty config:

```ini
theme = light:omniwm-light,dark:omniwm-dark
```

Ghostty then switches between them by itself when macOS changes appearance. On macOS, Ghostty reads `~/.config/ghostty/config.ghostty` and `config` (or the same names under `$XDG_CONFIG_HOME/ghostty`), then `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty` and `config`, each followed by the files it includes with `config-file`, and the last `theme` line wins. OmniWM checks all of them. If none selects the OmniWM themes, the Ghostty row offers **Add to Ghostty Config…**; if a later file sets a different theme, it says **Another Ghostty config sets a different theme** and offers **Fix Ghostty Config…**. Either shows the exact change to every file that needs one (the new line, and each other `theme =` line commented out), backs each file up, refuses if any of them changed since you reviewed it, and then reloads Ghostty.

When the palette changes, OmniWM reloads Ghostty with its AppleScript `reload_config` action. The first time, macOS asks whether OmniWM may control Ghostty; if you decline, the row says so and you can allow it later in **System Settings → Privacy & Security → Automation**. Ghostty 1.3 or newer is needed for AppleScript. The Ghostty Quake terminal reloads with it.

## kitty

Turning an app on reloads it once, even when its files already match. Turning on **kitty** writes `light-theme.auto.conf` and `dark-theme.auto.conf` to `~/.config/kitty/`. kitty 0.38 or newer reads these files automatically and switches between them with macOS appearance, so `kitty.conf` doesn't change. OmniWM reloads running kitty instances with `SIGUSR1` when the palette changes. kitty 0.50 or newer also picks up these files on that reload the first time they appear; an older kitty that was already open when you turned kitty on uses them after a restart or at the next light and dark switch ([kitty's changelog](https://sw.kovidgoyal.net/kitty/changelog/)), and the row says so. If you already have these files, from `kitten themes` for example, OmniWM shows the change and keeps a backup before it replaces them.

## herdr

herdr keeps its colors in `[theme.custom]` inside its own `~/.config/herdr/config.toml`, so turning on **herdr** first shows exactly how that table will change and saves a backup. From then on OmniWM rewrites only that table for the current appearance. It finds the table with a TOML scanner that understands indented headers, strings and arrays, checks that every other setting in the file stays exactly the same, and leaves the file untouched if it would not. `panel_bg`, `surface0`, `surface1` and `surface_dim` stay `reset`, so herdr keeps the terminal's background and transparency.

After the terminals reload, OmniWM runs `herdr server reload-config`. A herdr client attached to another machine draws that machine's interface with this terminal's colors, so with **Also reload saved herdr machines** on, OmniWM also runs `herdr --machine <label> server reload-config` for each enabled saved machine. A herdr server that isn't running is fine: it reads the new colors when it starts.

If you edit `[theme.custom]` yourself while herdr theming is on, OmniWM stops updating it and the row offers **Review and Replace…**.

## Neovim

Turning on **Neovim** writes `~/.config/nvim/lua/omniwm.lua` (under `$XDG_CONFIG_HOME` when it is set), a Lua module holding both the light and the dark palette, rewritten when the palette changes, plus a one-line `colors/omniwm.lua` so `:colorscheme omniwm` works. The module picks the palette from Neovim's `'background'` option, which Neovim sets from your terminal's real background color at startup ([`:h 'background'`](https://neovim.io/doc/user/options.html#'background'); it asks the terminal with an OSC 11 query). So Neovim matches the terminal it runs in, even over SSH, and can't disagree with Ghostty. When `'background'` changes, Neovim reloads the `omniwm` colorscheme, and the module also reapplies itself on `OptionSet background`. `setup()` hands sixteen base16 colors to [base16-nvim](https://github.com/RRethy/base16-nvim), which you need installed, then colors Telescope and mini.pick. This follows the approach of [Noctalia's community Neovim template](https://github.com/noctalia-dev/community-templates/tree/94e9c105622b3d8f18955f51e57a3ae72748c43e/neovim), base16-nvim plus a `SIGUSR1` reload; the module itself is written independently of that template's code.

The module listens for `SIGUSR1` through Neovim's own `Signal` event, in an autocommand group it clears on every load, so reloads never stack up. After each write, OmniWM runs `pkill -USR1 -U <your user> -x nvim`, so every Neovim you are running reloads the module; Neovim [handles that signal itself](https://neovim.io/doc/user/autocmd.html#Signal), so an instance that doesn't load the module just ignores it. If you switch to another colorscheme, reloads and `'background'` changes leave it alone until you run `:colorscheme omniwm` again. Neovim reloads after the terminals and before herdr. OmniWM never edits your Neovim config or creates plugin files; it only writes those two files of its own. Add these two lines yourself; the App Theming page has them with a Copy button:

```lua
{ "RRethy/base16-nvim" }, -- in your lazy.nvim plugin list
local ok, omniwm = pcall(require, "omniwm") if ok then omniwm.setup() end -- in init.lua, after your plugins
```

`setup({ transparent = true })` clears the background of `Normal`, `NormalNC`, `SignColumn`, `EndOfBuffer`, `LineNr`, `FoldColumn`, `CursorLineNr`, `CursorLineSign` and `CursorLineFold`, so a translucent terminal shows through, like catppuccin.nvim's `transparent_background`. The module remembers the options from your first `setup` call, so every reload keeps them.

Each time the colors are applied, including after a reload or a change of `'background'`, the module sets `vim.g.colors_name = "omniwm"`, fires `ColorScheme` when base16-nvim didn't, and fires a `User` event named `OmniWMColors`. Its `data` holds `base00` to `base0F` and the named colors `bg`, `surface`, `text`, `accent`, `secondary`, `tertiary`, `error`, `red`, `green`, `yellow`, `blue`, `magenta` and `cyan`, all as `#rrggbb`, so you can reapply your own overrides on every recolor:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "OmniWMColors",
  callback = function(event)
    vim.api.nvim_set_hl(0, "WinSeparator", { fg = event.data.accent })
  end,
})
```

For each palette, `base00` is `background`, `base01` `surface`, `base02` `elevatedSurface`, `base03` and `base04` the muted and secondary text (terminal colors 8 and 7), and `base05` to `base07` the foreground. `base08` to `base0F` take base16's usual roles from the terminal colors in the same positions: red (`ansi1`), orange (between `ansi1` and `ansi3`), yellow (`ansi3`), green (`ansi2`), cyan (`ansi6`), blue (`ansi4`), magenta (`ansi5`) and bright red (`ansi9`). They follow **Terminal Colors** with the terminal, so with **Follow Palette** and a wallpaper palette they carry the wallpaper's accents, and Neovim always matches the terminal. All eight keep at least 4.5:1 contrast with the background.

## Custom templates

**Add Custom Template…** themes any app with a text config. A custom template has:

- a template file, and optionally a separate one for dark mode;
- an output file inside `~/.config` (or `$XDG_CONFIG_HOME`) or `~/Library/Application Support`;
- what to do after writing: nothing, or reload Ghostty, kitty or herdr.

A custom template is rendered for the current macOS appearance and rendered again when it changes. With **Do Nothing**, the app has to watch its own file, or you reload it by hand; OmniWM never runs a command of your own after writing. A reload hook for other apps may come later as a separate change.

OmniWM never writes inside its own configuration or state folders, `~/Library/LaunchAgents` or `~/.ssh`, follows a symbolic link only when it stays inside your home folder and out of those folders, and never overwrites a file it didn't write without showing you the change and keeping a backup first.

## Template placeholders

Placeholders follow [matugen](https://github.com/InioX/matugen/wiki/Configuration)'s `colors.<name>.<variant>.<format>` form, the same shape [Noctalia's templates](https://docs.noctalia.dev/noctalia/v5.4.0/theming/templates/) use:

```text
{{colors.<name>.<variant>.<format>}}
```

| Part | Values |
| --- | --- |
| `name` | Any palette role: `background`, `surface`, `elevatedSurface`, `highestSurface`, `foreground`, `secondaryForeground`, `mutedForeground`, `border`, `accent`, `accentForeground`, `accentContainer`, `accentContainerForeground`, `secondaryAccent`, `secondaryContainer`, `secondaryContainerForeground`, `tertiaryAccent`, `tertiaryContainer`, `tertiaryContainerForeground`, `success`, `warning`, `error`, `focus`, `shadow`, `scrim`, `badge`, `red`, `orange`, `yellow`, `green`, `mint`, `teal`, `cyan`, `blue`, `indigo`, `purple`, `pink`, `brown`, `gray`; a terminal color `ansi0` to `ansi15`; or a base16 color `base00` to `base0F`, as the Neovim module uses them. |
| `variant` | `default` (the appearance being rendered), `light` or `dark`. |
| `format` | `hex` (`#rrggbb`), `hex_stripped` (`rrggbb`), `rgb` (`rgb(r, g, b)`), `rgba` (`rgba(r, g, b, a)`), `red`, `green`, `blue` (0 to 255) and `alpha` (0 to 1). |

`{{mode}}` is `light` or `dark`. Write `\{{` for a literal `{{`. Spaces inside the braces are allowed. An unknown placeholder or a `{{` without `}}` on the same line stops that template, and the row shows the line. Templates are only filled in: nothing in a template is ever run.

### Terminal colors

`ansi0` to `ansi15`, which the Ghostty and kitty themes, herdr's colors and your templates all use, are made from the palette for each appearance. **Settings → App Theming → Terminal Colors** (`terminalColors` in the settings file) chooses how:

- **Follow Palette** (`"palette"`, the default). A palette that only carries accent roles, such as the wallpaper palette, fills the six colors from its accents, the way [Noctalia](https://docs.noctalia.dev/) does for wallpaper themes ([its mapping](https://github.com/noctalia-dev/noctalia/blob/b096daa50f842c22332a04dbafd7d561d15825be/src/theme/fixed_palette.cpp), and its `terminal_colors = "palette"` setting): red is `error`, green `accent`, yellow `secondaryAccent`, blue `tertiaryAccent`, magenta a lighter `accent` and cyan a lighter `secondaryAccent`. The terminal then matches the wallpaper, though red and green may not look red and green in diffs. A theme that sets its own `red`, `green`, `yellow`, `blue`, `purple` and `cyan`, as the bundled themes do, keeps them exactly.
- **Standard Hues** (`"standard"`). The six colors keep the palette's `red`, `green`, `yellow`, `blue`, `purple` and `cyan` (Apple's system colors when the palette doesn't set them), tinted toward `accent`: each hue turns toward the accent's hue by half the difference, at most 15 degrees, so red stays red and the order of hues never changes, and its saturation moves partway toward the accent's. Familiar `ls` and `git` colors, with a hint of the wallpaper.

| Colors | From |
| --- | --- |
| `ansi0` | `surface` (`highestSurface` when following an accent-only palette), for backgrounds |
| `ansi1` to `ansi6` | as chosen above |
| `ansi7`, `ansi8`, `ansi15` | `secondaryForeground`, `mutedForeground`, `foreground` |
| `ansi9` to `ansi14` | the colors above, moved further from the background |

Either way, colors 1 to 15 always keep at least 4.5:1 contrast with `background`: a color that is too faint keeps its hue and gets lighter or darker until it reads. Colors 1 to 6 and 9 to 14 are kept distinct when the palette allows; when it doesn't, as with a gray background and gray roles, a color may repeat but still reads.

### Example

A template for [Alacritty](https://alacritty.org):

```toml
[colors.primary]
background = "{{colors.background.default.hex}}"
foreground = "{{colors.foreground.default.hex}}"

[colors.normal]
black = "{{colors.ansi0.default.hex}}"
red = "{{colors.ansi1.default.hex}}"
green = "{{colors.ansi2.default.hex}}"
yellow = "{{colors.ansi3.default.hex}}"
blue = "{{colors.ansi4.default.hex}}"
magenta = "{{colors.ansi5.default.hex}}"
cyan = "{{colors.ansi6.default.hex}}"
white = "{{colors.ansi7.default.hex}}"
```

Save it as, for example, `~/.config/omniwm/app-themes/alacritty.toml`, set the output to `~/.config/alacritty/omniwm.toml`, and add `"~/.config/alacritty/omniwm.toml"` to `general.import` in `alacritty.toml`.

## Credits

The **Follow Palette** terminal colors adapt [Noctalia](https://github.com/noctalia-dev/noctalia) (MIT); retain [its notice](https://github.com/OmniNull/OmniWM/blob/main/Resources/Licenses/Noctalia-LICENSE.txt). The Neovim module follows the approach of Noctalia's community Neovim template, base16-nvim with a `SIGUSR1` reload, without its code.

## Backups and state

Backups go to `~/.local/state/omniwm/app-theming/backups/` (`omniwm-dev` for the Dev app); OmniWM keeps the newest 20. The same folder holds `state.json`, which records what OmniWM last wrote to each file, so it can tell your edits from its own, and any reload still owed after a failure, which it retries on the next update. See [`appTheming`](/config/settings-reference/#apptheming) for the settings keys.
