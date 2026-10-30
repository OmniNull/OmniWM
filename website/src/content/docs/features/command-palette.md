---
title: Command Palette
description: Search windows, app menus, clipboard history, OmniWM commands, applications, and files from one keyboard-driven palette.
sidebar:
  order: 2
---

Open the palette with `Control + Option + Space` (configurable with the other [keyboard shortcuts](/guides/keyboard-shortcuts/)) and search windows, app menus, clipboard history, OmniWM commands, applications, or files from one shared surface.

## Modes

The palette has six modes:

- **Windows** — `Cmd + 1`
- **Menu** — `Cmd + 2`
- **Clipboard** — `Cmd + 3`
- **Commands** — `Cmd + 4`
- **Launcher** — `Cmd + 5`
- **Files** — `Cmd + 6`

`Tab` / `Shift + Tab` cycle forward or backward through the available modes.

## Navigating results

- `Up` / `Down` move the selection. In Launcher and Files grids they move between rows; once results are focused, `Left` / `Right` move within a row.
- `Enter` activates the selected result.
- In Windows mode, `Shift + Enter` summons the selected window to the right of the focused one when available, or moves it into an empty current workspace, including floating windows. Floating windows cannot be summoned right.
- In Launcher and Files, `Cmd + Enter` or `Cmd + R` reveals an app or file target in Finder.
- When category chips are available, type `/`, choose one with `Left` / `Right`, and press `Tab` or `Enter`. With an empty query, `Backspace` clears the selected category.
- In Files, `Cmd + Y` toggles the selected file's preview. `Space` does the same once results are focused, for example after pressing `Down`.
- `Escape` closes an open file preview first, or dismisses the palette when no preview is open.

Windows from macOS-hidden apps remain searchable and carry a **Hidden** badge; selecting one unhides its app and focuses that exact window. In Menu mode, results always show keyboard shortcuts when available.

## Window marks

In Windows mode, **Mark selected window** (`Control + Option + Shift + M`) names the selected result, and **Remove mark** (`Control + Option + Shift + R`) removes one of its marks. The buttons remain available if an enabled global shortcut uses either chord. Marks appear beside windows and match searches by name. Names are unique across windows and last until the window closes or OmniWM quits. Separate global set/remove actions default to **Unassigned** in [Settings > Keyboard Shortcuts](/guides/keyboard-shortcuts/#focus).

## OmniWM commands

Commands mode lists OmniWM actions by category, including actions without a shortcut. Each row shows the layout it supports and its current shortcut, or **Unassigned** / **No shortcut** when none is available. Type to search across command names, related terms, and shortcuts; results then appear in relevance order without category headings.

Select a compatible command and press `Enter` to run it. Commands that require a different layout remain visible with a dimmed row and cannot be run until that layout is active.

## Launcher

:::note[Unreleased]
Saved commands, scripts and CLI tool discovery are available when building from `main`. In v0.7.6, this mode is named Applications and searches applications.
:::

Launcher combines applications and saved commands or scripts. Its filters are **All**, **Apps**, **Saved**, and **CLI Tools**. All searches apps and saved entries together; automatically discovered CLI tools appear only in CLI Tools. Apps has the existing grid/list view and category filters.

Use the **Add** menu to add an Application, Command, or Script, or open **Settings > Launcher** to manage entries. Give an entry a name, then choose its working folder, terminal, and shell. **Advanced Options** contains search keywords, entry type, and a custom shell executable. Commands support Nushell, fish, zsh, and Bash; command text uses the selected shell's syntax. Scripts can use their shebang or an explicit interpreter. Add arguments individually to preserve spaces and quotation marks, and choose a working directory when needed.

**Run Now** runs the current saved-entry draft while keeping the editor open; **Save** persists your edits. The one-off CLI flow keeps **Run** and **Save Entry** separate. Removing a saved entry asks for confirmation and leaves app and script files on disk.

Each entry can use the default terminal, the built-in Ghostty Quake Terminal, Terminal, Ghostty, iTerm2, kitty, or Background execution. Terminal commands open fresh sessions with output retained after completion. The built-in choice requires the Ghostty Quake provider to be enabled. Terminal and iTerm2 may request macOS Automation access. Background runs show their completion, exit status, and bounded output in Launcher settings.

CLI discovers executable files from the selected shell's PATH, with standard Homebrew/Nix locations and configured extra folders included. Select a result to set arguments, directory, and terminal, then Run or Save Entry. Shell aliases and functions are not listed as CLI executables. Refresh Launcher after changing shell startup configuration or installing tools.

App discovery combines macOS's registered app catalog with standard app folders, active Nix profile application directories, and folders added in Launcher settings. Default Homebrew cask, nix-darwin, and Home Manager app folders are covered, including symlinks and Finder aliases. Homebrew formula apps kept only inside a keg need an added app folder or saved app entry. OmniWM scans these selected locations rather than traversing the Nix store or Homebrew Cellar.

`Enter` opens an app or runs a saved entry. A running app focuses its recent managed window. Saved entries offer Edit and Remove in their context menu. The existing `applications` IPC mode name still opens Launcher.

For declarative entries and execution defaults, see the [Launcher settings reference](/config/settings-reference/#launcher).

## Files

Files opens as a browse grid, with a remembered grid/list choice. Type to search the macOS metadata index, use type chips to narrow results, and press `Enter` to open or `Cmd + Enter` to reveal the selection. Before typing, Files shows recent documents and, when the local prediction cache is readable, suggested documents.

Typed app/file searches use the available macOS Spotlight ranking integration. Without a query, app browsing lists suggestions and apps alphabetically.

## How search ranks results

Window search uses substring matching with tiered ranking. Mark-name matches rank first, followed by window title, app name, and workspace name. Typing part of the literal word "hidden" surfaces windows of hidden apps. Title, app, and workspace matches closer to the start rank higher; ties and mark matches retain the window list's order.

With no search, windows use focus history, then app name and title, with hidden apps last.

## Clipboard history

Clipboard history is off by default. Open Clipboard mode (`Cmd + 3`) and click **Enable**, or set `clipboard.historyEnabled = true` in `settings.toml`.

History retains text, rich text, HTML, images, file references, and safe native formats within the [configured limits](/config/settings-reference/#clipboard). Items marked concealed, transient, or autogenerated, including recognized password-manager markers, are skipped. You can add exact pasteboard type identifiers to `clipboard.ignoredTypes` to exclude more content.

In Clipboard mode, `Enter` or a row click copies the selected entry. `Shift + Enter` and the row's **Paste** button paste into the previous app when that target is still available. The row menu offers **Paste Without Formatting** for text, Pin/Unpin, and Delete. The selected entry has a scrollable preview. Clear removes unpinned history; pinned entries remain until deleted.

History is deduplicated — copying identical content again updates the existing entry and moves it to the top instead of creating a duplicate. Entries are written with owner-only file permissions to OmniWM's state directory (`${XDG_STATE_HOME:-$HOME/.local/state}/omniwm`), outside dotfile-oriented config storage.

## Menu Anywhere

`Control + Option + M` opens the frontmost app's menus at your cursor. Available items depend on what the app exposes through macOS Accessibility.
