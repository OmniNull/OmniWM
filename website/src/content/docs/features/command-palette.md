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

## Unified search

**Unreleased — available when building from `main`.** Unified search runs one query across several modes at once, the way Alfred and Spotlight do. Turn on **Enable Unified Search** in **Settings > Command Palette**, or set `commandPalette.unifiedSearch = true` in `settings.toml`. Open Command Palette (`Control + Option + Space`) then shows unified search, with no mode tabs. The per-mode actions, **Command Palette: Windows** through **Command Palette: Files**, still open one mode with its previews, chips and pin and delete actions. That is true whether they come from a shortcut, IPC, an OmniShell launcher widget, or Commands mode.

- **Searched modes** decide which modes unified search covers and the order of their groups. The defaults are Windows, Launcher, Commands, and Files. Menu reads the frontmost app's menus each time the palette opens. Clipboard needs clipboard history turned on.
- Before you type, unified search lists windows in focus-history order, as Windows mode does. When Windows is not a searched mode, the palette stays collapsed until you type.
- Results appear as up to three **Top Hits**, followed by one group per searched mode. Each group shows at most five rows. A **Show all in …** row opens that mode with the same query when it has more results. A top hit does not appear again in its group.
- Top hits learn from what you pick. Picking a result after typing a query remembers it for that query, and it then ranks first whenever you type the start of that query again. Results you picked more often come first, then the most recent pick. A learned result only appears while its mode still returns it. Any remaining slots go to the closest title matches, with ties broken by your mode order. A remembered window stands for its app and brings back that app's most recently focused window. Apps and files learn from the Launcher's launch history, so a launch from Launcher or Files mode counts too. Clipboard picks are never remembered. **Clear Pick History** in Settings forgets the windows, commands, and menu items unified search learned; Launcher keeps its launch history.
- `Enter`, `Shift + Enter`, and `Cmd + Enter` do what they do in the selected row's own mode. `Cmd + 1`, `Cmd + 2`, and `Cmd + 3` open the first, second, and third top hit. The window mark chords work only while a window row is selected. `Up` / `Down` move through every row and wrap around, and `Tab` / `Shift + Tab` jump to the next or previous group.
- Apps and Files results arrive after the other groups. Until you move the selection, it stays on the first row as results arrive, and `Enter` or `Cmd + 1` to `Cmd + 3` pressed before Apps and Files answer runs once they do, unless you move the selection while it waits. After you move the selection, late results leave it where it is, and `Enter` acts right away. If new results drop the row you moved to, the selection goes back to following the first row. While you keep typing, the previous Apps and Files rows stay until the new results replace them.

## Palette shortcuts

**Unreleased — available when building from `main`.** While the palette is open, it reserves its own shortcuts in every mode: the mode keys above, `Cmd + Enter` and `Cmd + R` (reveal in Finder in Launcher and Files, like `Enter` in other modes), `Cmd + Y` (preview in Files), and the window mark chords. A global shortcut on one of these chords does not run while the palette is open and works again once it closes; Settings shows a note under that shortcut. Other global shortcuts, including the one that opens the palette, keep working while it is open.

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

In Windows mode, **Mark selected window** (`Control + Option + Shift + M`) names the selected result, and **Remove mark** (`Control + Option + Shift + R`) removes one of its marks. Marks appear beside windows and match searches by name. Names are unique across windows and last until the window closes or OmniWM quits. Separate global set/remove actions default to **Unassigned** in [Settings > Keyboard Shortcuts](/guides/keyboard-shortcuts/#focus).

## OmniWM commands

Commands mode lists OmniWM actions by category, including actions without a shortcut. Each row shows the layout it supports and its current shortcut, or **Unassigned** / **No shortcut** when none is available. Type to search across command names, related terms, and shortcuts; results then appear in relevance order without category headings.

Select a compatible command and press `Enter` to run it. Commands that require a different layout remain visible with a dimmed row and cannot be run until that layout is active.

## Launcher

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
