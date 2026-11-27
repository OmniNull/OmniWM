---
title: init.luau Reference
description: Add shortcuts, palette commands, event handlers, timers and window rules in Luau, with limits and recipes.
sidebar:
  order: 2
---

`init.luau` is optional and lives next to `settings.luau`, so by default it's `~/.config/omniwm/init.luau`. It adds shortcuts, palette commands, event handlers, timers and window rules. Settings values stay in [`settings.luau`](/config/configuration/).

Saving `init.luau`, or any file it loads with `require("./name")`, reloads it. For editor completion and type checking, register `omniwm-config.d.luau` as described in [Configuration](/config/configuration/). It also lists every typed form of each call on this page.

## When a load fails

- **The last script keeps running.** OmniWM keeps the last version that loaded, with every shortcut, command, event handler, timer and rule. At startup, nothing from a broken file runs.
- **A notice shows what went wrong.** It names the file, line and error, and offers **Edit init.luau**. The error is also listed under **Issues Detected** in the status menu. Both clear once a save loads.
- **`settings.luau` problems show first.** If both files have one, the `settings.luau` notice appears first.
- **A rule ID already in Settings rejects the whole script.** The notice names the conflicting ID.

## When a callback fails

- **The same notice shows it.** An error inside a running callback, a refused action, or a press dropped because too many are waiting shows in the notice with its file, line and error. It's also listed on **Settings → Keyboard Shortcuts** and in the system log, but not under **Issues Detected**.
- **A load error comes first.** While a save that didn't load is reported, the notice shows that error. The callback error is still listed on **Settings → Keyboard Shortcuts**.
- **A repeat stays quiet.** The same error from the same line changes nothing, so a notice you dismissed stays dismissed. A different error shows the notice again.
- **A save that loads clears it,** together with any load error.

`omniwm.log(...)` writes to the system log. To watch it:

```bash
log stream --predicate 'subsystem == "com.barut.OmniWM" AND category == "config"'
```

Use `omniwm.notify(text)` to show a message on screen instead.

## Functions

Shortcuts, commands, events, timers and rules are declared while the file loads. Callbacks queue actions and effects, which OmniWM applies in order once the callback succeeds. An action that needs the focused window can fail if focus has moved by then, which stops the remaining actions.

| Call | What it does |
| --- | --- |
| `omniwm.keymap.set(chord, action, opts?)` | Binds a shortcut, such as `"Control+Option+K"`, to an action. `opts.modeKey` also binds a key for Prefix and Window mode. With `opts.mode`, the chord is a key inside a [key mode](#key-modes) instead. |
| `omniwm.keymap.mode(name)` | Declares a [key mode](#key-modes) and returns the action that enters it. |
| `omniwm.keymap.set(chord, function(ctx) … end, opts?)` | Runs a function instead. `opts` can also hold `reads`. |
| `omniwm.command(name, function(ctx) … end, opts?)` | Adds a command to the command palette. |
| `omniwm.on(event, function(e) … end, opts?)` | Handles an [event](#events). |
| `omniwm.timer({ afterSeconds = n }, fn)` or `omniwm.timer({ everySeconds = n }, fn)` | Runs `fn` once or repeatedly, and returns a value with `cancel()`. Pass a function and `{ reads = … }` to give it a context. |
| `omniwm.cmd.<name>(…)` | Builds a built-in action for `keymap.set` or `dispatch`, such as `omniwm.cmd.focus("left")`. |
| `omniwm.act.openApp(bundleId)`, `omniwm.act.launch(argv)`, `omniwm.act.notify(text)` | Builds an action that opens an app, launches a program or shows a notice. |
| `omniwm.dispatch(action)` | Queues an action from a callback. |
| `omniwm.dispatch("window", action, id, …)` | Queues an action on one window by its ID; see [window actions](#window-actions). |
| `omniwm.openApp(bundleId)`, `omniwm.launch(argv)`, `omniwm.notify(text)` | Queues an effect from inside a callback. |
| `omniwm.rule { … }` | Adds a [window rule](#window-rules). |
| `omniwm.store.get(key)`, `omniwm.store.set(key, value)`, `omniwm.store.clear(key?)` | Reads, saves or removes a [saved value](#saved-values) from a callback. |
| `omniwm.log(…)` | Writes to the system log. |

`launch` and `openApp` were `run` and `open` before, so `wm.act.run({ "/usr/bin/say", "Done" })` is now `wm.act.launch({ "/usr/bin/say", "Done" })` and `wm.open("com.apple.TextEdit")` is now `wm.openApp("com.apple.TextEdit")`. OmniShell widgets keep their own `omniwm.run` and `omniwm.open`, which mean something else there; see [widget services](/omnishell/reference/services/).

`argv` is a list such as `{ "/usr/bin/open", "-a", "TextEdit" }`. OmniWM runs the program directly, not through a shell.

## Built-in commands

Use the first word of an [`omniwmctl` command](/reference/cli/commands/) as the camelCase member of `omniwm.cmd`. Pass workspace numbers, column and window indices, and slots as positive safe integers (at most 2⁵³ − 1) or their existing strings. Keep literal words and sizes as strings. For example, `switch-workspace slot 2` becomes `omniwm.cmd.switchWorkspace("slot", 2)`. The generated `omniwm-config.d.luau` definition lists the members and their accepted arguments.

```lua
local wm = omniwm
wm.keymap.set("Control+Option+2", wm.cmd.switchWorkspace(2))
```

## Key modes

A key mode gives plain keys their own meaning until you leave it, like Hyprland's submaps. `omniwm.keymap.mode(name)` declares one and returns the action that enters it. Bind that action to a shortcut, or dispatch it from a callback. `omniwm.keymap.set(key, action, { mode = name })` binds a key inside the mode, and a function works there too.

- A key in a mode is one key, with Shift at most. Each mode keeps its own keys, so H can resize in one mode and move a window in another.
- Escape leaves the mode, and so does `omniwm.cmd.exitKeyboardMode()`. Keys the mode doesn't bind, and shortcuts with Command, Control or Option, still reach your apps, and the mode stays on.
- One mode is on at a time. Entering another mode, Pause, Prefix or Window mode replaces it. A mode has no timeout, and reloading `init.luau` leaves it.
- While a mode is on, the indicator shows its name and keys, and the `keybinds.submap` event reports its name.
- A name has up to 32 lowercase letters, digits, `-` and `_`, and starts with a letter. `normal`, `paused`, `prefix` and `window` are taken. A config declares at most 16 modes, each with 1 to 64 keys. An overlapping global chord in the same script rejects the load.
- A key in a mode can take over a global shortcut from Settings. That saved shortcut is inactive even outside the mode while the script binding is loaded.
- Key modes need Input Monitoring, like Prefix and Window mode.

## Callback context

A shortcut or palette callback receives `ctx`, with these fields:
- `ctx.windowId`: the focused window's ID;
- `ctx.bundleId`: its app;
- `ctx.workspace`: the workspace's name;
- `ctx.layout`: the workspace's layout;
- any lists you declared in `reads`.

## Reads

A callback sees a snapshot of the lists it declares. Shortcuts and palette commands capture their snapshot when queued. Declare them with `{ reads = { "workspaceWindows", "monitors" } }`.

| List | Rows |
| --- | --- |
| `workspaceWindows` | The windows on the callback's workspace |
| `windows` | Every managed window |
| `workspaces` | Workspaces, per monitor, in Next/Previous Workspace order |
| `monitors` | Displays, left to right, then top first |
| `placement` | Where the focused window sits: one record, not a list |
| `focusTarget` | The window the callback's workspace focuses: one record |
| `dwindle` | The callback's workspace's Dwindle tree: one record |
| `frames` | Adds frames to the window and monitor lists declared with it |
| `columns` | Adds Niri column numbers to the window lists declared with it |

The row fields are:
- **window:** `id`, `bundleId`, `title`, `workspace`, `monitor`, `floating`, `fullscreen` (`"native"` for macOS fullscreen, `"omniwm"` for OmniWM's, absent otherwise) and `minimized`, with `frames`, `frame`, and with `columns`, `column`;
- **workspace:** `id`, `name` and `monitor`;
- **monitor:** `id` and `name`, and with `frames`, `frame` and `visibleFrame`, the part the menu bar and Dock leave free.

A frame is `{ x, y, width, height }` in points, in the coordinates `omniwmctl query` uses: from the bottom-left corner of the main display, with `y` growing upward. A window's `frame` is where OmniWM last placed or saw it, not a fresh reading from macOS. It's absent while the window isn't on screen: on a workspace that isn't shown, minimized, hidden, on another macOS Space or in native fullscreen. Tiled windows of OmniShell apps have none.

`ctx.placement` describes the focused window, the one `ctx.windowId` names, and is absent without one. It has `workspace` and `display`, the window's workspace name and display ID. A tiled window on a Niri workspace also has:
- `column`: its column's position, counting from 1;
- `columns`: how many columns the workspace shows;
- `members`: the IDs of the windows in that column, in order, with inactive tabs but without minimized or hidden windows;
- `vertical`: `true` when the strip runs vertically. Moving a column `"up"` then takes it toward a larger `column`, and `"down"` toward a smaller one. In a horizontal strip, `"right"` and `"left"` do that.

`ctx.focusTarget` is the window OmniWM focuses when you switch to the callback's workspace. For `workspace.active`, that is the workspace just switched to. It has `id` and `nativeFullscreen`, which is `true` when the window sits in its own macOS fullscreen Space and `focus` can bring it forward. It's absent when the workspace has no window to focus.

`ctx.dwindle` describes the Dwindle tree of the callback's workspace. It has `workspaceId`, `revision`, `preselect` when a direction is pending (`"left"`, `"right"`, `"up"` or `"down"`), and `nodes`, the tree in preorder:
- A split is `{ kind = "split", orientation, ratio }`, followed by its first and then its second subtree. The first is on the left of a `"horizontal"` split and at the bottom of a `"vertical"` one. `ratio` is `1` for an even split.
- A leaf is `{ kind = "leaf", members, active }`: the IDs of the windows in that tile in tab order, and the position of the one shown, counting from 1. Minimized and hidden windows keep their place.

An empty workspace has no nodes. `revision` is text that changes when the tree, a ratio, a tile's windows or tab, or the preselect changes, and stays the same otherwise; a window that closes and opens again counts as a change. `ctx.dwindle` is absent on other layouts and until Dwindle has laid out the workspace's current windows, for example in a `window.close` callback before the layout catches up. A tree with more than 256 windows gives `nil`, with `truncated.dwindle` set to `true`.

`omniwm.dispatch("dwindle", "replace", tree)` replaces the Dwindle layout of the workspace you're on with `tree`, in the same format as `ctx.dwindle`. Read `ctx.dwindle`, build a changed copy, and pass it back:
- `workspaceId` and `revision` come from that read. The workspace must still be the one shown, and its tree mustn't have changed since.
- `nodes` lists every tiled window of the workspace exactly once, inactive tabs included, as one complete tree. Each split is followed by both of its subtrees; each leaf has at least one window and an `active` position. A ratio is from `0` to `2`, with `1` for an even split.
- The focused window must stay the shown tab of its group, and the windows' minimum sizes must fit the display.
- It's refused while a window of the workspace is minimized, hidden, fullscreen, in a scratchpad or on another macOS desktop, while you drag or resize a tile or swipe between workspaces, and until Dwindle has laid out a window that just opened or closed.

A callback can replace one tree. A refusal changes nothing, names the reason in the config notice, and stops the callback's remaining actions. Passing the tree back unchanged does nothing, and Undo returns to the layout before the replacement.

A window's `column` is the position of its Niri column, counting from 1, numbered like `focus-column` and `omniwmctl query`'s `column-index`. Windows in one column, inactive tabs included, share it, and it counts columns scrolled out of view too. Floating windows, Dwindle windows and windows the layout leaves out, such as minimized ones, have none.

A window `id` is text such as `"9b2f6c0e4d1a7b3c5e8f0a2d4c6e8b1f.48213.912345"`. It names the same window until OmniWM quits, and actions reach that window while OmniWM manages it. A monitor `id` is the display's number as text, such as `"69734208"`.

Each list holds up to 256 rows and 128 KiB, not counting frames or column numbers. `truncated.<list>` is `true` when a list was cut.

## Events

`omniwm.on(name, function(e) … end, { reads = … })`. Every event also carries the lists you declared.

| Event | Fields | Delivery |
| --- | --- | --- |
| `workspace.active` | `id`, `name` | Latest |
| `window.active` | `id`, `bundleId` | Latest |
| `monitor.focused` | `id`, `name` | Latest |
| `keybinds.submap` | `name`: `normal`, `paused`, `prefix`, `window` or a [key mode's](#key-modes) name | Latest |
| `config.reloaded` | none | Latest |
| `window.open`, `window.close`, `window.move_to_workspace` | `id`, `bundleId`, `workspaceId`, `workspaceName`, `previousWorkspaceId`, `previousWorkspaceName`, `missed` | Each |
| `workspace.created`, `workspace.removed`, `workspace.move_to_monitor` | `id`, `name`, `monitorId`, `monitorName`, `previousMonitorId`, `previousMonitorName`, `missed` | Each |
| `monitor.added`, `monitor.removed`, `monitor.layout_changed` | `id`, `name`, `frame`, `previousFrame`, `visibleFrame`, `previousVisibleFrame`, `missed` | Each |
| `window.title` | `id`, `bundleId`, `title`, `missed` | Latest per window |
| `window.minimize` | `id`, `bundleId`, `minimized`, `missed` | Latest per window |
| `window.fullscreen` | `id`, `bundleId`, `fullscreen`, `missed` | Latest per window |
| `window.update_state` | `id`, `bundleId`, `floating`, `missed` | Latest per window |

- **Latest:** if several of these happen before the handler runs, it gets the last one.
- **Each:** queued in order, with up to 64 waiting.
- **`missed`:** counts events dropped because 64 were already waiting.

Handlers last until the next reload.

## Window actions

`omniwm.dispatch("window", action, id, …)` takes these actions. Take `id` from `ctx.windowId`, a row or an event. IDs from `omniwmctl` don't work here.

| Action | Extra arguments |
| --- | --- |
| `focus`, `navigate`, `summon-right`, `close` | none |
| `move-to-workspace` | workspace number, a string workspace ID or name, or a [destination table](#destination-tables) |
| `move-column-to-first`, `move-column-to-last` | none |
| `move-column-to-index` | position as a number or string, such as `2` or `"2"` |
| `move-column` | `"left"`, `"right"`, `"up"` or `"down"` |
| `place-in-own-column` | position as a number or string, such as `2` or `"2"` |
| `toggle-container-full-primary-span`, `reset-window-secondary-span` | none |
| `set-container-primary-span`, `set-window-primary-span`, `set-window-secondary-span` | a size such as `"+10%"` or `"50%"` |
| `cycle-window-primary-span`, `cycle-window-secondary-span` | `"forward"` or `"backward"` |
| `toggle-column-tabbed`, `toggle-floating` | none |
| `set-floating-frame` | a table with any of `x`, `y`, `width` and `height` |
| `assign-to-scratchpad` | slot as a number or string, such as `1` or `"1"` |
| `gather` | a list of 1 to 64 IDs in place of `id`, then optionally `"workspace"`, `"monitor"` or `"all"` |

A numeric workspace selector addresses that workspace's numbered ID. A string can also name a workspace by its display name. Numeric positions and slots follow the same positive safe integer rule as built-in commands, and scratchpad slots must be in the supported range.

`set-floating-frame` moves or resizes a floating window, in the coordinates of [frames](#reads). Fields you leave out keep their current value. The window moves as needed to stay on its display's visible frame, and keeps a size larger than that. A tiled window doesn't move, so dispatch `toggle-floating` first in the same callback. Windows attached to another window, such as sheets, are refused. A minimized or hidden window doesn't change. A window on a workspace that isn't shown gets the frame when you switch to it.

`gather` puts the listed windows into one column on the callback's Niri workspace, in the list's order, without changing focus. By default it reaches windows on that workspace only; `"monitor"` adds the other workspaces on its display, and `"all"` every workspace. It's all or nothing: an unknown, repeated or out-of-reach ID, or a window that can't join a column, such as a floating, minimized or hidden one, refuses the whole gather and nothing moves. So does switching away from the callback's workspace before it runs. Like any refused action, it stops the callback's remaining actions.

`place-in-own-column` gives just that window a column of its own at that position on its Niri workspace. A window that shares its column, even with a minimized or hidden window, leaves it; a window alone in its column moves with it. A larger position puts it last. Like the other column actions, it doesn't change focus.

`focus` also takes a table of checks, made when the focus runs rather than when it's queued:
- `{ targetOf = id }` focuses the window only if workspace `id` is still the focused workspace and the window is still the one it focuses. Focus is also compared with the focus state OmniWM captured for the callback: whatever has focus now, a window, an OmniWM panel or nothing, must be the captured owner or this window, and a pending focus request must be absent, the captured request, or one for this window. Focus that moved away and came back can still pass.
- `{ nativeFullscreen = true }` focuses it only if it still sits in its own fullscreen Space.

When a check fails, nothing happens, so a callback that was still queued can't pull you back after you've moved on.

### Destination tables

`move-to-workspace` also takes a table that picks a display instead of a workspace. The window goes to the workspace that display shows when the move runs.
- `{ display = id }` uses a monitor `id` from `monitors` or a row.
- `{ neighbor = "left", of = id }` uses the next display in that direction from `of`. Without `of`, it starts from the window's display. With no display there, nothing moves.
- `column = n` places the window as the `n`th column on a Niri workspace. A larger `n` puts it last. Without `column`, it becomes the last column. Dwindle workspaces ignore it.
- `fromEdge = true` with `neighbor` and `of` moves the callback's own window only if it is still on the workspace it was on when the key was pressed, on display `of`, and in the outermost Niri column in that direction. Otherwise nothing moves, so a second queued press can't skip a display.

## Rules and shortcuts: two homes

Hand-edited rules and one shortcut per action live in `settings.luau` and the Settings window. Rules that code builds and extra key chords live here. An enabled shortcut in `init.luau` takes over any overlapping Settings shortcut. The saved assignment remains visible and marked in **Settings → Keyboard Shortcuts**. See [Configuration](/config/configuration/#rules-and-shortcuts-two-homes) for how the two combine.

## Window rules

`omniwm.rule { … }` takes the same fields as [`appRules`](/config/settings-reference/#apprules) in `settings.luau`.
- **Matchers:** `bundleId`, `appNameSubstring`, `titleSubstring`, `titleRegex`, `axRole` and `axSubrole`.
- **Effects:** `layout` (`"auto"`, `"tile"` or `"float"`), `assignToWorkspace`, `assignToWorkspaceForAllWindows`, `initialContainerPrimarySpan`, `minWidth`, `minHeight` and `scratchpad`.
- **`id`:** optional, but it must not repeat an ID from Settings.

A title rule is checked again when a window's title changes.

## Saved values

`omniwm.store` keeps small values through reloads and restarts, such as a list of apps a callback picked. It works in callbacks, not while the file loads.

- **Reading:** `omniwm.store.get(key)` returns the value, or `nil`. A list comes back as a new table, so changing it changes nothing until you `set` it.
- **Saving:** `omniwm.store.set(key, value)` takes a boolean, a finite number, a string or a list of strings. `set(key, nil)` removes the key, as `omniwm.store.clear(key)` does, and `omniwm.store.clear()` removes them all.
- **When it's saved:** a callback sees its own changes right away. OmniWM saves them together when the callback succeeds, and a failed callback saves nothing. Setting the value a key already has writes nothing.
- **Keys:** 1 to 64 letters, digits, `.`, `_` and `-`, and case matters. Dotted keys such as `work.apps` keep modules apart.
- **The file:** `~/.local/state/omniwm/script-store.json` by default. If its contents aren't valid, `get`, `set` and `clear(key)` report an error and leave it alone, and `omniwm.store.clear()` starts over. If the file can't be read at all, for example because of its permissions, every store call reports that and nothing replaces it. If a save fails, the callback reports an error at its first change and its actions don't run.

A window ID lasts only while OmniWM runs, so save bundle IDs or names instead.

## Limits

- **Libraries:** base, table, string, math, bit32, utf8 and os. There's no io, coroutine or debug, and `print`, `getfenv` and `setfenv` are removed.
- **Memory:** 32 MiB.
- **Time:** 100 ms of Lua CPU to load, and 25 ms per callback.
- **Source:** up to 1 MiB, in up to 64 modules.
- **Declarations:** up to 4,096 each of shortcuts, rules and callback functions, and up to 4,096 stored actions sharing 1 MiB of text.
- **Per run:** up to 64 actions or effects, and separately up to 64 log lines. The log cap also applies while loading.
- **Waiting presses:** up to 8 shortcut or command presses can wait. Further presses are dropped with an error.
- **Timers:** up to 16, each at least 1 second.
- **`launch`:** up to 64 arguments of 4 KiB each, 32 KiB in all.
- **Other text:** bundle IDs up to 255 bytes, and notice text up to 512 bytes.
- **Saved values:** up to 128 keys, strings up to 4 KiB, lists up to 64 strings, and 64 KiB once saved. A callback can change the store up to 64 times.

## Recipes

Put these in `init.luau`, and save the file to apply them.

**Grow the focused Niri column.** Control + Option + K adds 12 percentage points to the column's share of the available space. Change `+12%` to choose the step for this key. The standard resize shortcuts use **Settings → Layouts → Niri → Resize Increment**.

```lua
local wm = omniwm
wm.keymap.set("Control+Option+K", wm.cmd.setContainerPrimarySpan("+12%"))
```

**Float an app's windows.** This rule floats new TextEdit documents. Substitute another app's bundle ID to float its windows.

```lua
omniwm.rule { bundleId = "com.apple.TextEdit", layout = "float" }
```

**Open TextEdit from a shortcut or the command palette.** Build its action once and use it in both places.

```lua
local wm = omniwm
local textEdit = wm.act.openApp("com.apple.TextEdit")
wm.keymap.set("Control+Option+Shift+J", textEdit)
wm.command("Open TextEdit", function()
    wm.dispatch(textEdit)
    wm.notify("Opening TextEdit")
end)
```

Use `wm.act.openApp`, `wm.act.launch` or `wm.act.notify` whenever you need an action to bind or save. A callback can build one too, then dispatch it later while the same config is loaded. Identical actions share storage.

Inside a callback, `wm.openApp`, `wm.launch` and `wm.notify` queue effects. OmniWM performs them in order when the callback succeeds and discards them if it fails.

**Vim-style keys alongside the defaults.** Option with H, J, K or L focuses, and adding Shift moves the window.

Leave **Toggle Workspace Layout** assigned to its default Option + Shift + L and save this recipe. That chord now moves the focused window right. The config notice names the chord, Toggle Workspace Layout and the recipe's file and line. Remove `bind("L", "right")` and save to restore the Toggle Workspace Layout shortcut.

```lua
local wm = omniwm
local function bind(letter: string, direction: "left" | "down" | "up" | "right")
    wm.keymap.set("Option+" .. letter, wm.cmd.focus(direction))
    wm.keymap.set("Option+Shift+" .. letter, wm.cmd.move(direction))
end
bind("H", "left")
bind("J", "down")
bind("K", "up")
bind("L", "right")
```

**Stop at the first and last workspace.** These keys step through the display's workspaces without wrapping around.

They don't change the built-in Next/Previous Workspace, the palette or `omniwmctl`. With Hide Empty Workspaces on, they still stop on empty workspaces.

```lua
local wm = omniwm
local function bind(chord: string, step: number)
    wm.keymap.set(chord, function(ctx: ConfigContext)
        local rows = ctx.workspaces
        if not rows or not ctx.workspace or (ctx.truncated and ctx.truncated.workspaces) then return end
        local monitor: string? = nil
        for _, row in rows do
            if row.name == ctx.workspace then
                monitor = row.monitor
                break
            end
        end
        if not monitor then return end
        local names: {string} = {}
        for _, row in rows do
            if row.monitor == monitor then table.insert(names, row.name) end
        end
        local current = table.find(names, ctx.workspace)
        if current and names[current + step] then
            wm.dispatch(wm.cmd.switchWorkspace("slot", current + step))
        end
    end, { reads = { "workspaces" } })
end
bind("Control+Option+Shift+Period", 1)
bind("Control+Option+Shift+Comma", -1)
```

**Send a window to the other display.** With two displays side by side, one key moves the focused window to whichever display it isn't on. Three or more displays need a different approach.

```lua
local wm = omniwm
local left = wm.cmd.moveToMonitor("left")
local right = wm.cmd.moveToMonitor("right")
wm.keymap.set("Control+Option+Shift+M", function(ctx: ConfigContext)
    local monitors, windows = ctx.monitors, ctx.workspaceWindows
    if not monitors or #monitors ~= 2 or not windows then return end
    for _, window in windows do
        if window.id == ctx.windowId then
            wm.dispatch(if window.monitor == monitors[1].id then right else left)
            return
        end
    end
end, { reads = { "workspaceWindows", "monitors" } })
```

**Move a window and follow it, for some keys only.** **Settings → Displays → Behavior → Follow Window to Monitor** does this for every move. Leave that setting off and these keys follow only for themselves, with a brief second focus change.

```lua
local wm = omniwm
local function moveAndFollow(chord: string, workspace: number)
    wm.keymap.set(chord, function(ctx: ConfigContext)
        local id = ctx.windowId
        if not id then return end
        wm.dispatch("window", "move-to-workspace", id, workspace)
        wm.dispatch("window", "focus", id)
    end)
end
moveAndFollow("Control+Option+Shift+1", 1)
moveAndFollow("Control+Option+Shift+2", 2)
```

**Return to a floating window after closing a tile.** This tracks focus changes to remember the floating window you left for a tiled one. When you close that tiled window, it refocuses the floating window. Quick focus changes can be merged before it sees them, and you may see a second focus change.

```lua
local wm = omniwm
type Focus = { id: string, floating: boolean }
local last: { [string]: Focus? } = {}
local predecessor: { [string]: string? } = {}

wm.on("window.active", function(e: ConfigWindowEvent)
    local rows = e.windows
    if not rows or (e.truncated and e.truncated.windows) then return end
    for _, w in rows do
        if w.id == e.id then
            local before = last[w.workspace]
            if before and before.id ~= w.id then
                if not before.floating then
                    for _, other in rows do
                        if other.id == before.id then predecessor[before.id] = nil end
                    end
                end
                if not w.floating then
                    predecessor[w.id] = if before.floating then before.id else nil
                end
            end
            last[w.workspace] = { id = w.id, floating = w.floating }
            return
        end
    end
end, { reads = { "windows" } })

wm.on("window.close", function(e: ConfigWindowEdge)
    local target = predecessor[e.id]
    predecessor[e.id] = nil
    if not target or e.missed ~= 0 then return end
    for _, w in e.windows or {} do
        if w.id == target and w.workspace == e.workspaceName and w.floating and not w.minimized then
            wm.dispatch("window", "focus", target)
            return
        end
    end
end, { reads = { "windows" } })
```

**Cycle the focused window through your displays.** Control + Option + Shift + N moves it to the next display, left to right and then top first, wrapping at the end. Adding P instead of N goes the other way.

```lua
local wm = omniwm
local function cycle(chord: string, step: number)
    wm.keymap.set(chord, function(ctx: ConfigContext)
        local monitors, placement, id = ctx.monitors, ctx.placement, ctx.windowId
        if not monitors or not placement or not id then return end
        for index, monitor in monitors do
            if monitor.id == placement.display then
                local target = monitors[(index - 1 + step) % #monitors + 1]
                wm.dispatch("window", "move-to-workspace", id, { display = target.id })
                return
            end
        end
    end, { reads = { "placement", "monitors" } })
end
cycle("Control+Option+Shift+N", 1)
cycle("Control+Option+Shift+P", -1)
```

**Send a window to the next display as its own column.** Control + Option + Shift + H and L move the focused window to the display on that side. Unlike Move to Monitor, the window doesn't join a column there.

```lua
local wm = omniwm
local function send(chord: string, direction: "left" | "right")
    wm.keymap.set(chord, function(ctx: ConfigContext)
        if ctx.windowId then
            wm.dispatch("window", "move-to-workspace", ctx.windowId, { neighbor = direction })
        end
    end)
end
send("Control+Option+Shift+H", "left")
send("Control+Option+Shift+L", "right")
```

**Move a window along the strip, out of its group and onto the next display.** Control + Option + Shift + Right Bracket moves the focused window one column forward, and Left Bracket one column back. A window that shares its column with another visible window leaves it first. From the outermost column, it moves to the next display. On a Niri workspace there, it becomes the first column going forward and the last going back.

```lua
local wm = omniwm
local function alongStrip(forward: boolean): ConfigFunction
    return function(ctx)
        local p, id = ctx.placement, ctx.windowId
        if not id or not p or not p.column or not p.display then return end
        local direction: "left" | "right" | "up" | "down" =
            if p.vertical then (if forward then "up" else "down") else (if forward then "right" else "left")
        if #p.members > 1 then
            wm.dispatch("window", "place-in-own-column", id, if forward then p.column + 1 else p.column)
        elseif p.column == (if forward then p.columns else 1) then
            wm.dispatch("window", "move-to-workspace", id,
                { neighbor = direction, of = p.display, fromEdge = true, column = if forward then 1 else nil })
        else
            wm.dispatch("window", "move-column", id, direction)
        end
    end
end
wm.keymap.set("Control+Option+Shift+]", alongStrip(true), { reads = { "placement" } })
wm.keymap.set("Control+Option+Shift+[", alongStrip(false), { reads = { "placement" } })
```

**Land on a native fullscreen window when you switch to its workspace.** Switching to a workspace normally selects a fullscreen window's placeholder. This brings the window forward instead, so macOS shows its fullscreen Space. If you switch away or focus another window before it runs, it does nothing.

```lua
omniwm.on("workspace.active", function(e: ConfigWorkspaceEvent)
    local target = e.focusTarget
    if target and target.nativeFullscreen and e.id then
        omniwm.dispatch("window", "focus", target.id, { targetOf = e.id, nativeFullscreen = true })
    end
end, { reads = { "focusTarget" } })
```

**Center a floating window.** Control + Option + C centers the focused floating window on its display's visible frame.

```lua
local wm = omniwm
wm.keymap.set("Control+Option+C", function(ctx: ConfigContext)
    local windows, monitors = ctx.workspaceWindows, ctx.monitors
    if not windows or not monitors then return end
    for _, window in windows do
        local frame = window.frame
        if window.id == ctx.windowId and window.floating and frame then
            for _, monitor in monitors do
                local area = monitor.visibleFrame
                if monitor.id == window.monitor and area then
                    wm.dispatch("window", "set-floating-frame", window.id, {
                        x = area.x + (area.width - frame.width) / 2,
                        y = area.y + (area.height - frame.height) / 2,
                    })
                end
            end
        end
    end
end, { reads = { "workspaceWindows", "monitors", "frames" } })
```

**Snap a floating window to halves and quarters.** Control + Option + Left and Right Arrow fill the left and right half of the display's visible frame. Control + Option + Q, W, A and S fill its quarters: top left, top right, bottom left and bottom right. The fractions measure from the top-left corner, and the recipe turns them into frames. Tiled windows stay where the layout puts them.

```lua
local wm = omniwm
local function place(chord: string, left: number, top: number, width: number, height: number)
    wm.keymap.set(chord, function(ctx: ConfigContext)
        local placement, monitors, id = ctx.placement, ctx.monitors, ctx.windowId
        if not placement or not monitors or not id then return end
        for _, monitor in monitors do
            local area = monitor.visibleFrame
            if monitor.id == placement.display and area then
                wm.dispatch("window", "set-floating-frame", id, {
                    x = area.x + left * area.width,
                    y = area.y + (1 - top - height) * area.height,
                    width = width * area.width,
                    height = height * area.height,
                })
            end
        end
    end, { reads = { "placement", "monitors", "frames" } })
end
place("Control+Option+Left Arrow", 0, 0, 0.5, 1)
place("Control+Option+Right Arrow", 0.5, 0, 0.5, 1)
place("Control+Option+Q", 0, 0, 0.5, 0.5)
place("Control+Option+W", 0.5, 0, 0.5, 0.5)
place("Control+Option+A", 0, 0.5, 0.5, 0.5)
place("Control+Option+S", 0.5, 0.5, 0.5, 0.5)
```

**Give every Niri column the same width.** Control + Option + Shift + 2 asks for half of the space along the strip for every column on the workspace, and Control + Option + Shift + 3 for a third, without moving focus. In a vertical strip that's the columns' height. It sizes the columns that are there now, including ones scrolled out of view, and leaves your sizing defaults alone. **Balance Sizes** (Option + Shift + B) instead restores every column's default span and resets the sizes within each column. With more than 64 columns the keys only show a notice, because one callback can queue at most 64 actions.

```lua
local wm = omniwm
local limit = 64
local function equalize(chord: string, span: string)
    wm.keymap.set(chord, function(ctx: ConfigContext)
        local rows = ctx.workspaceWindows
        if not rows or (ctx.truncated and ctx.truncated.workspaceWindows) then return end
        local first: { [number]: string } = {}
        local count = 0
        for _, row in rows do
            local column = row.column
            if column and not first[column] then
                first[column] = row.id
                count += 1
            end
        end
        if count > limit then
            wm.notify("Too many columns to resize at once")
            return
        end
        for _, id in first do
            wm.dispatch("window", "set-container-primary-span", id, span)
        end
    end, { reads = { "workspaceWindows", "columns" } })
end
equalize("Control+Option+Shift+2", "50%")
equalize("Control+Option+Shift+3", "33.333%")
```

**Summon a group of apps.** These rules put Slack, Discord and Telegram in scratchpad slot 2 as OmniWM starts managing their windows, and Control + Option + Shift + C shows or hides them together on the workspace you're on. Use the same slot number in both places. The windows float while they're in the slot.

```lua
local wm = omniwm
local chat = { "com.tinyspeck.slackmacgap", "com.hnc.Discord", "ru.keepcoder.Telegram" }
for _, bundleId in chat do
    wm.rule { bundleId = bundleId, scratchpad = 2 }
end
wm.keymap.set("Control+Option+Shift+C", wm.cmd.scratchpad("toggle", 2))
```

**Gather an app group into one column.** Control + Option + Shift + G collects Safari and Ghostty windows from every workspace into one column on the Niri workspace you're on, in the order the windows list gives them. Floating, minimized and fullscreen windows stay where they are. If a matching window is on a Dwindle workspace, the gather refuses and nothing moves. A truncated windows list does nothing rather than gather part of the group.

```lua
local wm = omniwm
local group: { [string]: boolean } = { ["com.apple.Safari"] = true, ["com.mitchellh.ghostty"] = true }
local limit = 64
wm.keymap.set("Control+Option+Shift+G", function(ctx: ConfigContext)
    local rows = ctx.windows
    if not rows or (ctx.truncated and ctx.truncated.windows) then return end
    local ids: { string } = {}
    for _, row in rows do
        if row.bundleId and group[row.bundleId] and not row.floating and not row.minimized and not row.fullscreen then
            table.insert(ids, row.id)
        end
    end
    if #ids > limit then
        wm.notify("Too many windows to gather at once")
    elseif #ids > 0 then
        wm.dispatch("window", "gather", ids, "all")
    end
end, { reads = { "windows" } })
```

**Rotate a Dwindle workspace.** Control + Option + Shift + R turns every split of the Dwindle workspace you're on: side by side becomes stacked and stacked becomes side by side, keeping each split's ratio and every tab. Press it again to turn it back.

```lua
local wm = omniwm
wm.keymap.set("Control+Option+Shift+R", function(ctx: ConfigContext)
    local tree = ctx.dwindle
    if not tree then return end
    local nodes: { ConfigDwindleNode } = {}
    for index, node in tree.nodes do
        if node.kind == "split" then
            local turned = if node.orientation == "horizontal" then "vertical" else "horizontal"
            nodes[index] = { kind = "split", orientation = turned, ratio = node.ratio }
        else
            nodes[index] = node
        end
    end
    wm.dispatch("dwindle", "replace", {
        workspaceId = tree.workspaceId, revision = tree.revision, preselect = tree.preselect, nodes = nodes,
    })
end, { reads = { "dwindle" } })
```

**Resize and move with the same keys.** Control + Option + Shift + Y turns on a resize mode where H and L shrink and grow the selected Dwindle window across, and Control + Option + Shift + U a move mode where they move the focused window. Q also leaves the move mode, and Escape leaves either one.

```lua
local wm = omniwm
local resize = wm.keymap.mode("resize")
local move = wm.keymap.mode("move")

wm.keymap.set("Control+Option+Shift+Y", resize)
wm.keymap.set("Control+Option+Shift+U", move)

wm.keymap.set("H", wm.cmd.resize("horizontal", "shrink"), { mode = "resize" })
wm.keymap.set("L", wm.cmd.resize("horizontal", "grow"), { mode = "resize" })
wm.keymap.set("H", wm.cmd.move("left"), { mode = "move" })
wm.keymap.set("L", wm.cmd.move("right"), { mode = "move" })
wm.keymap.set("Q", wm.cmd.exitKeyboardMode(), { mode = "move" })
```

**Remember a workspace's apps.** **Remember Work Apps** in the command palette saves the apps on the workspace you're on. **Open Work Apps** opens them again, after a reload or restart too, and **Forget Work Apps** clears the list.

```lua
local wm = omniwm
local key = "work.apps"

wm.command("Remember Work Apps", function(ctx: ConfigContext)
    local windows = ctx.workspaceWindows
    if not windows or (ctx.truncated and ctx.truncated.workspaceWindows) then
        return
    end
    local apps: { string } = {}
    local seen: { [string]: boolean } = {}
    for _, window in windows do
        local app = window.bundleId
        if app and not seen[app] then
            seen[app] = true
            table.insert(apps, app)
        end
    end
    wm.store.set(key, apps)
    wm.notify("Remembered " .. #apps .. " apps")
end, { reads = { "workspaceWindows" } })

wm.command("Open Work Apps", function()
    local apps = wm.store.get(key)
    if type(apps) == "table" then
        for _, app in apps do
            wm.openApp(app)
        end
    end
end)

wm.command("Forget Work Apps", function()
    wm.store.clear(key)
end)
```
