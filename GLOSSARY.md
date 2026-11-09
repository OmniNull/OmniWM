# OmniWM

A tiling window manager for macOS. This glossary names the concepts users and scripts see through OmniWM's commands and queries.

## Language

### Focus

**Focus history**:
The order in which managed windows (tiled, floating and scratchpad) were last focused, most recent first. It starts empty each time OmniWM launches.
_Avoid_: MRU list, recent windows

**Focus rank**:
A window's position in the focus history, where 0 is the most recently focused window. A window that hasn't been focused since launch has no focus rank.
_Avoid_: MRU index, focus order

**Tiled focus history**:
The narrower history `focus previous` walks, covering only tiled windows.
_Avoid_: focus history (when only tiled windows are meant)

### Shortcuts

**Global shortcut**:
A key chord or mouse button bound to an OmniWM action in Settings > Keyboard Shortcuts, active wherever the user is working.
_Avoid_: global hotkey, binding (in user-facing text)

**Palette shortcut**:
A key chord that only acts while the command palette is open, such as switching palette modes or revealing a file. While the palette is open it takes precedence over a global shortcut on the same chord.
_Avoid_: palette action, local shortcut, palette hotkey

**Palette modifier**:
The configurable modifier or modifier combination shared by the palette shortcuts that use Command by default.
_Avoid_: command modifier, palette command key

### Command palette

**Palette mode**:
One of the six single-purpose views of the command palette: Windows, Menu, Clipboard, Commands, Launcher and Files.
_Avoid_: tab, source, category

**Unified search**:
An optional palette view that searches several palette modes from one query and shows the results grouped by palette mode. When it is on, it replaces the mode tabs, and a single palette mode opens only through its own action.
_Avoid_: unified mode, all mode, search everywhere

**Searched modes**:
The palette modes that unified search covers, in the order their groups appear.
_Avoid_: sources, enabled modes

**Top hits**:
Up to three results shown above the groups in unified search, chosen from all searched modes using what the user picked before for similar queries.
_Avoid_: best match, top results

**Pick history**:
What unified search remembers about the results the user picked for each query; top hits are chosen from it. Clipboard picks are never part of it.
_Avoid_: learned picks, search history
