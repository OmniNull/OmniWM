---
title: Configuration
description: Edit settings in the Settings window, Luau, or TOML and recover from invalid edits.
sidebar:
  order: 1
---

OmniWM keeps settings in `~/.config/omniwm/`. If `XDG_CONFIG_HOME` is an absolute path, it uses `$XDG_CONFIG_HOME/omniwm/` instead. OmniWM picks a settings file at launch. It uses `settings.luau` when present and `settings.toml` when that is the only settings file. If neither exists, it creates `settings.luau` with defaults. The Settings window and your editor work on the selected file.

## TOML settings

**Unreleased.** To use an existing `settings.toml`, keep it in the config directory. If an earlier launch created `settings.luau`, move that file to a backup name and restart OmniWM.

TOML uses the same keys and defaults as the [settings reference](/config/settings-reference/). This example sets an eight-point inner gap.

```toml
[gaps]
size = 8
```

The Settings window rewrites TOML with standard formatting. On its first write to a file, it keeps the original bytes in `settings.toml.before-omniwm-edit` next to the target file.

## Luau settings

The file returns one Luau table. This example sets an eight-point inner gap and uses the default values for the other settings.

```lua
--!strict
local settings: OmniWMSettings = {
    gaps = { size = 4 * 2 },
}
return settings
```

You can use local variables, functions and `require("./sizes")` or `require("../shared/sizes")` to load nearby `.luau` files. Each path starts at the folder of the file that calls `require`. Changes to the main file or any loaded helper reload your settings. Shortcuts, events and timers belong in the separate, optional `init.luau`.

To enable editor completion and type checking, open the config folder in luau-lsp, select the standard platform, enable the new solver, and register the bundled `omniwm-config.d.luau` as a definitions file. For an app installed in Applications, it lives at `/Applications/OmniWM.app/Contents/Resources/OmniWM_OmniWM.bundle/Contents/Resources/omniwm-config.d.luau`. Keep the `--!strict` and `OmniWMSettings` annotation shown above. See the [settings reference](/config/settings-reference/) for keys, defaults and examples.

## init.luau

Shortcuts, palette commands, events, timers and window rules go in the optional `init.luau` next to the settings file. The [init.luau Reference](/config/init-luau/) covers its functions, limits and recipes.

## Opening the file

Click OmniWM's status bar icon and use:

- **Reveal Settings File** shows the active settings file in Finder.
- **Edit Settings File** — opens it in your editor.

If you delete the file while OmniWM is running, it keeps the working values and asks you to restore the file. To start over instead, these commands can create a new file with defaults.

## Settings window

The searchable Settings window groups controls by task. **Desktop** contains Styles & Widgets, Menu Bar and Network & Permissions; **Windows** contains Workspaces, Layouts, Displays, App Rules, and Overview. **Appearance** holds motion, borders, and system-wide window corners. **Layouts** has Spacing, Niri, and Dwindle tabs. App Rules now uses the same settings window, with Save/Revert and discard protection for drafts. Clipboard retention limits and scratchpad labels can be edited in the file; clipboard history can be enabled from the [Command Palette's Clipboard mode](/features/command-palette/#clipboard-history).

The Settings window is a managed floating window. It opens on the active workspace and appears in the window switcher, Overview and focus history, and it hides and returns with its workspace like any other floating window. Opening Settings again focuses the existing window. Other OmniWM windows, such as the Command Palette and the Welcome window, stay unmanaged.

macOS manages **Start at Login** and stores **System-wide Window Corners** as a system preference.

**Settings > Appearance > App & Motion** carries a **System-wide Window Corners** control (macOS 26.4+). It writes the system-wide preference, so it changes standard Mac app windows everywhere — including windows OmniWM does not manage — and apps that draw their own window chrome may ignore it. Affected apps must be fully quit and reopened before the new radius applies.

## Live reload and recovery

- In Luau, changing a literal in Settings edits that value in place and preserves surrounding code and comments. A **Code** mark beside a calculated value shows its source line. Click the mark to inspect the expression.
- Settings asks before replacing a calculated Luau value. If a function calculates a whole group, the question shows which other values will become fixed. **Cancel** keeps the code. If the source changes while the question is open, the old approval expires.
- A typo such as `gaps.ouetr` or a retired shortcut ID makes OmniWM reject the entire file, including other edits in the same save. While running, it keeps the last working settings, shows the file and line in an error, and blocks saves from the Settings window until you fix the file. **If you start OmniWM with an invalid file, every setting from that file uses its default.** Invalid values and broken helpers follow the same rule.
- Interface language changes take effect at the next launch.
- A symlink to your dotfiles stays a symlink when Settings writes through it. If the target is read-only, edit its source instead.

## Runtime state lives elsewhere

Clipboard history, update-check timestamps, the persisted window restore catalog (including Niri column and Dwindle tree placements), the Quake terminal's custom frame, and the last palette mode live in `${XDG_STATE_HOME:-$HOME/.local/state}/omniwm`. `XDG_STATE_HOME` is honored only when it is an absolute path beginning with `/`; otherwise OmniWM uses `~/.local/state/omniwm`.

The separate **OmniWM Dev** app uses `omniwm-dev` instead of `omniwm` for both its config and state directories. See [Building from Source](/developers/building/) for the development build workflow.

## What's in the file

The full schema is documented key by key in the [Settings Reference](/config/settings-reference/). At the top level:

| Table / array | Covers |
| --- | --- |
| [`general`](/config/settings-reference/#general) | Hotkeys master switch, Hyper key, default layout, updates, IPC, animations, language |
| [`focus`](/config/settings-reference/#focus) | Focus-follows-mouse and monitor-edge focus behavior |
| [`mouseWarp`](/config/settings-reference/#mousewarp) | Cursor warping between monitors |
| [`routing`](/config/settings-reference/#routing) | macOS vs. custom routing and saved arrangements per connected display set |
| [`monitors`](/config/settings-reference/#monitors) | Optional ranking that decides which connected display is Main, Secondary, and so on |
| [`gaps`](/config/settings-reference/#gaps) | Inner and outer gaps |
| [`niri`](/config/settings-reference/#niri) | Scrolling (Niri) layout options |
| [`dwindle`](/config/settings-reference/#dwindle) | Dwindle (BSP) layout options |
| [`borders`](/config/settings-reference/#borders) | Focused-window border |
| [`overview`](/config/settings-reference/#overview) | Overview visibility, zoom, input and colors |
| [`windowSwitcher`](/config/settings-reference/#windowswitcher) | Command-Tab / Option-Tab window switcher |
| [`keyboardModes`](/config/settings-reference/#keyboardmodes) | Shortcut pause timeout |
| [`workspaceBar`](/config/settings-reference/#workspacebar) | Workspace bar appearance and behavior |
| [`island`](/config/settings-reference/#island) | Dynamic Island master switch |
| [`gestures`](/config/settings-reference/#gestures) | Mouse and trackpad gestures |
| [`statusBar`](/config/settings-reference/#statusbar) | Menu bar icon extras |
| [`statusMenu`](/config/settings-reference/#statusmenu) | Status menu panel contents |
| [`hiddenBar`](/config/settings-reference/#hiddenbar) | Menu bar icon concealment |
| [`clipboard`](/config/settings-reference/#clipboard) | Clipboard history limits |
| [`launcher`](/config/settings-reference/#launcher) | Saved applications, commands, scripts and CLI launches; execution defaults and discovery folders |
| [`commandPalette`](/config/settings-reference/#commandpalette) | Unified search and the palette modes it covers |
| [`quakeTerminal`](/config/settings-reference/#quaketerminal) | Drop-down terminal |
| [`scratchpads`](/config/settings-reference/#scratchpads) | Scratchpad slot labels |
| [`appearance`](/config/settings-reference/#appearance) | Light/dark appearance of OmniWM's own UI |
| [`shellPermissions`](/config/settings-reference/#shellpermissions) | Remembered OmniShell host/program decisions and built-in service switches |
| [`hotkeys`](/config/settings-reference/#hotkeys) | One entry per assignable action |
| [`workspaces`](/config/settings-reference/#workspaces) | Workspace definitions |
| [`appRules`](/config/settings-reference/#apprules) | Per-app window rules |
| [`monitor*Overrides`](/config/settings-reference/#per-monitor-overrides) | Per-monitor bar, orientation, Niri, Dwindle, and gap overrides |
