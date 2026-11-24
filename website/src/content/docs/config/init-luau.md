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
- **Conflicts reject the whole script.** A shortcut or rule ID that Settings already uses rejects the script, and the notice names it.
- **Callback errors stay quieter.** An error inside a running callback is listed on **Settings → Keyboard Shortcuts** and in the system log, not in a notice.

`omniwm.log(...)` writes to the system log. To watch it:

```bash
log stream --predicate 'subsystem == "com.barut.OmniWM" AND category == "config"'
```

Use `omniwm.notify(text)` to show a message on screen instead.

## Functions

Shortcuts, commands, events, timers and rules are declared while the file loads. Callbacks queue actions and effects, which OmniWM applies in order once the callback succeeds. An action that needs the focused window can fail if focus has moved by then, which stops the remaining actions.

| Call | What it does |
| --- | --- |
| `omniwm.keymap.set(chord, action, opts?)` | Binds a shortcut, such as `"Control+Option+K"`, to an action. `opts.modeKey` also binds a key for Prefix and Window mode. |
| `omniwm.keymap.set(chord, function(ctx) … end, opts?)` | Runs a function instead. `opts` can also hold `reads`. |
| `omniwm.command(name, function(ctx) … end, opts?)` | Adds a command to the command palette. |
| `omniwm.on(event, function(e) … end, opts?)` | Handles an [event](#events). |
| `omniwm.timer({ afterSeconds = n }, fn)` or `omniwm.timer({ everySeconds = n }, fn)` | Runs `fn` once or repeatedly, and returns a value with `cancel()`. Pass a function and `{ reads = … }` to give it a context. |
| `omniwm.cmd(word, …)` | Builds the action for a built-in command, such as `omniwm.cmd("focus", "left")`. Most words match the [`omniwmctl` commands](/reference/cli/commands/). |
| `omniwm.act.open(bundleId)`, `omniwm.act.run(argv)`, `omniwm.act.notify(text)` | Builds an action that opens an app, runs a program or shows a notice. |
| `omniwm.dispatch(action)` | Queues an action from a callback. |
| `omniwm.dispatch("window", action, id, …)` | Queues an action on one window by its ID; see [window actions](#window-actions). |
| `omniwm.open(bundleId)`, `omniwm.run(argv)`, `omniwm.notify(text)` | Queues an effect from inside a callback. |
| `omniwm.rule { … }` | Adds a [window rule](#window-rules). |
| `omniwm.log(…)` | Writes to the system log. |

`argv` is a list such as `{ "/usr/bin/open", "-a", "TextEdit" }`. OmniWM runs the program directly, not through a shell.

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

The row fields are:
- **window:** `id`, `bundleId`, `title`, `workspace`, `monitor`, `floating`, `fullscreen` (native or OmniWM fullscreen) and `minimized`;
- **workspace:** `id`, `name` and `monitor`;
- **monitor:** `id` and `name`.

Each list holds up to 256 rows and 128 KiB. `truncated.<list>` is `true` when a list was cut.

## Events

`omniwm.on(name, function(e) … end, { reads = … })`. Every event also carries the lists you declared.

| Event | Fields | Delivery |
| --- | --- | --- |
| `workspace.active` | `id`, `name` | Latest |
| `window.active` | `id`, `bundleId` | Latest |
| `monitor.focused` | `id`, `name` | Latest |
| `keybinds.submap` | `name`: `normal`, `paused`, `prefix` or `window` | Latest |
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

`omniwm.dispatch("window", action, id, …)` takes these actions:

| Action | Extra arguments |
| --- | --- |
| `focus`, `navigate`, `summon-right`, `close` | none |
| `move-to-workspace` | workspace name |
| `move-column-to-first`, `move-column-to-last` | none |
| `move-column-to-index` | position as a string, such as `"2"` |
| `move-column` | `"left"`, `"right"`, `"up"` or `"down"` |
| `toggle-container-full-primary-span`, `reset-window-secondary-span` | none |
| `set-container-primary-span`, `set-window-primary-span`, `set-window-secondary-span` | a size such as `"+10%"` or `"50%"` |
| `cycle-window-primary-span`, `cycle-window-secondary-span` | `"forward"` or `"backward"` |
| `toggle-column-tabbed`, `toggle-floating` | none |
| `assign-to-scratchpad` | slot as a string, such as `"1"` |

## Window rules

`omniwm.rule { … }` takes the same fields as [`appRules`](/config/settings-reference/#apprules) in `settings.luau`.
- **Matchers:** `bundleId`, `appNameSubstring`, `titleSubstring`, `titleRegex`, `axRole` and `axSubrole`.
- **Effects:** `layout` (`"auto"`, `"tile"` or `"float"`), `assignToWorkspace`, `assignToWorkspaceForAllWindows`, `initialContainerPrimarySpan`, `minWidth`, `minHeight` and `scratchpad`.
- **`id`:** optional, but it must not repeat an ID from Settings.

A title rule is checked again when a window's title changes.

## Limits

- **Libraries:** base, table, string, math, bit32, utf8 and os. There's no io, coroutine or debug, and `print`, `getfenv` and `setfenv` are removed.
- **Memory:** 32 MiB.
- **Time:** 100 ms of Lua CPU to load, and 25 ms per callback.
- **Source:** up to 1 MiB, in up to 64 modules.
- **Declarations:** up to 4,096 each of shortcuts, rules and callback functions, and up to 4,096 stored actions sharing 1 MiB of text.
- **Per run:** up to 64 actions or effects, and separately up to 64 log lines. The log cap also applies while loading.
- **Waiting presses:** up to 8 shortcut or command presses can wait. Further presses are dropped with an error.
- **Timers:** up to 16, each at least 1 second.
- **`run`:** up to 64 arguments of 4 KiB each, 32 KiB in all.
- **Other text:** bundle IDs up to 255 bytes, and notice text up to 512 bytes.

## Recipes

Put these in `init.luau`, and save the file to apply them.

**Grow the focused Niri column.** Control + Option + K adds 12 percentage points to the column's share of the available space. Change `+12%` to choose the step for this key. The standard resize shortcuts use **Settings → Layouts → Niri → Resize Increment**.

```lua
local wm = omniwm
wm.keymap.set("Control+Option+K", wm.cmd("set-container-primary-span", "+12%"))
```

**Float an app's windows.** This rule floats new TextEdit documents. Substitute another app's bundle ID to float its windows.

```lua
omniwm.rule { bundleId = "com.apple.TextEdit", layout = "float" }
```

**Open TextEdit from a shortcut or the command palette.** Build its action once and use it in both places.

```lua
local wm = omniwm
local textEdit = wm.act.open("com.apple.TextEdit")
wm.keymap.set("Control+Option+Shift+J", textEdit)
wm.command("Open TextEdit", function()
    wm.dispatch(textEdit)
    wm.notify("Opening TextEdit")
end)
```

Use `wm.act.open`, `wm.act.run` or `wm.act.notify` whenever you need an action to bind or save. A callback can build one too, then dispatch it later while the same config is loaded. Identical actions share storage.

Inside a callback, `wm.open`, `wm.run` and `wm.notify` queue effects. OmniWM performs them in order when the callback succeeds and discards them if it fails.

**Vim-style keys alongside the defaults.** Option with H, J, K or L focuses, and adding Shift moves the window. Each shortcut adds to the action's existing ones.

Option + Shift + L is Toggle Layout by default. A shortcut that Settings already uses rejects the script, so unassign that one in Settings first.

```lua
local wm = omniwm
local function bind(letter: string, direction: "left" | "down" | "up" | "right")
    wm.keymap.set("Option+" .. letter, wm.cmd("focus", direction))
    wm.keymap.set("Option+Shift+" .. letter, wm.cmd("move", direction))
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
            wm.dispatch(wm.cmd("switch-workspace", "slot", tostring(current + step)))
        end
    end, { reads = { "workspaces" } })
end
bind("Control+Option+Shift+Period", 1)
bind("Control+Option+Shift+Comma", -1)
```

**Send a window to the other display.** With two displays side by side, one key moves the focused window to whichever display it isn't on. Three or more displays need a different approach.

```lua
local wm = omniwm
local left = wm.cmd("move-to-monitor", "left")
local right = wm.cmd("move-to-monitor", "right")
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
local function moveAndFollow(chord: string, workspace: string)
    wm.keymap.set(chord, function(ctx: ConfigContext)
        local id = ctx.windowId
        if not id then return end
        wm.dispatch("window", "move-to-workspace", id, workspace)
        wm.dispatch("window", "focus", id)
    end)
end
moveAndFollow("Control+Option+Shift+1", "1")
moveAndFollow("Control+Option+Shift+2", "2")
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
