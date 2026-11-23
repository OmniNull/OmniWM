-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

declare extern type ConfigAction with
end

export type ConfigRule = {
    id: string?,
    bundleId: string?,
    appNameSubstring: string?,
    titleSubstring: string?,
    titleRegex: string?,
    axRole: string?,
    axSubrole: string?,
    layout: ("auto" | "tile" | "float")?,
    assignToWorkspace: string?,
    assignToWorkspaceForAllWindows: boolean?,
    initialContainerPrimarySpan: number?,
    minWidth: number?,
    minHeight: number?,
    scratchpad: number?,
}

export type ConfigRead = "workspaceWindows" | "windows" | "workspaces" | "monitors"
export type ConfigReadOptions = { reads: { ConfigRead } }
export type ConfigWindowRow = {
    read id: string, read bundleId: string?, read title: string?, read workspace: string,
    read monitor: string?, read floating: boolean, read fullscreen: boolean, read minimized: boolean,
}
export type ConfigWorkspaceRow = { read id: string, read name: string, read monitor: string? }
export type ConfigMonitorRow = { read id: string, read name: string }
export type ConfigLookups = {
    read workspaceWindows: { read [number]: ConfigWindowRow }?,
    read windows: { read [number]: ConfigWindowRow }?,
    read workspaces: { read [number]: ConfigWorkspaceRow }?,
    read monitors: { read [number]: ConfigMonitorRow }?,
    read truncated: { read workspaceWindows: boolean?, read windows: boolean?, read workspaces: boolean?, read monitors: boolean? }?,
}
export type ConfigContext = ConfigLookups & {
    read windowId: string?,
    read bundleId: string?,
    read workspace: string?,
    read layout: string?,
}

export type ConfigFunction = (context: ConfigContext) -> ()
export type ConfigTimerOptions = { read afterSeconds: number, read everySeconds: nil } | { read afterSeconds: nil, read everySeconds: number }
export type ConfigTimer = { read cancel: () -> () }

export type ConfigEventRect = { read x: number, read y: number, read width: number, read height: number }
export type ConfigWorkspaceEvent = ConfigLookups & { read id: string?, read name: string? }
export type ConfigWindowEvent = ConfigLookups & { read id: string?, read bundleId: string? }
export type ConfigMonitorEvent = ConfigLookups & { read id: string?, read name: string? }
export type ConfigSubmapEvent = ConfigLookups & { read name: string }
export type ConfigReloadEvent = ConfigLookups & {}
export type ConfigWindowEdge = ConfigLookups & { read id: string, read bundleId: string?, read workspaceId: string?, read workspaceName: string?, read previousWorkspaceId: string?, read previousWorkspaceName: string?, read missed: number }
export type ConfigWorkspaceEdge = ConfigLookups & { read id: string, read name: string, read monitorId: string?, read monitorName: string?, read previousMonitorId: string?, read previousMonitorName: string?, read missed: number }
export type ConfigMonitorEdge = ConfigLookups & { read id: string, read name: string, read frame: ConfigEventRect, read previousFrame: ConfigEventRect?, read visibleFrame: ConfigEventRect, read previousVisibleFrame: ConfigEventRect?, read missed: number }
export type ConfigWindowTitle = ConfigLookups & { read id: string, read bundleId: string?, read title: string, read missed: number }
export type ConfigWindowMinimize = ConfigLookups & { read id: string, read bundleId: string?, read minimized: boolean, read missed: number }
export type ConfigWindowFullscreen = ConfigLookups & { read id: string, read bundleId: string?, read fullscreen: boolean, read missed: number }
export type ConfigWindowState = ConfigLookups & { read id: string, read bundleId: string?, read floating: boolean, read missed: number }

export type ConfigEvents =
    { read on: (name: "workspace.active", callback: (event: ConfigWorkspaceEvent) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "window.active", callback: (event: ConfigWindowEvent) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "monitor.focused", callback: (event: ConfigMonitorEvent) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "keybinds.submap", callback: (event: ConfigSubmapEvent) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "config.reloaded", callback: (event: ConfigReloadEvent) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "window.open", callback: (event: ConfigWindowEdge) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "window.close", callback: (event: ConfigWindowEdge) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "window.move_to_workspace", callback: (event: ConfigWindowEdge) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "workspace.created", callback: (event: ConfigWorkspaceEdge) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "workspace.removed", callback: (event: ConfigWorkspaceEdge) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "workspace.move_to_monitor", callback: (event: ConfigWorkspaceEdge) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "monitor.added", callback: (event: ConfigMonitorEdge) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "monitor.removed", callback: (event: ConfigMonitorEdge) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "monitor.layout_changed", callback: (event: ConfigMonitorEdge) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "window.title", callback: (event: ConfigWindowTitle) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "window.minimize", callback: (event: ConfigWindowMinimize) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "window.fullscreen", callback: (event: ConfigWindowFullscreen) -> (), options: ConfigReadOptions?) -> () }
    & { read on: (name: "window.update_state", callback: (event: ConfigWindowState) -> (), options: ConfigReadOptions?) -> () }

export type ConfigCommands =
    { read cmd: (command: "focus", direction: "left" | "right" | "up" | "down") -> ConfigAction }
    & { read cmd: (command: "focus", word2: "previous") -> ConfigAction }
    & { read cmd: (command: "focus", word2: "down-or-left") -> ConfigAction }
    & { read cmd: (command: "focus", word2: "up-or-right") -> ConfigAction }
    & { read cmd: (command: "focus-window-in-column", window_index: string) -> ConfigAction }
    & { read cmd: (command: "focus-window", word2: "top") -> ConfigAction }
    & { read cmd: (command: "focus-window", word2: "bottom") -> ConfigAction }
    & { read cmd: (command: "focus-window", word2: "down-or-top") -> ConfigAction }
    & { read cmd: (command: "focus-window", word2: "up-or-bottom") -> ConfigAction }
    & { read cmd: (command: "focus-window-or-workspace-down") -> ConfigAction }
    & { read cmd: (command: "focus-window-or-workspace-up") -> ConfigAction }
    & { read cmd: (command: "focus-column", column_index: string) -> ConfigAction }
    & { read cmd: (command: "focus-column", word2: "first") -> ConfigAction }
    & { read cmd: (command: "focus-column", word2: "last") -> ConfigAction }
    & { read cmd: (command: "center-column") -> ConfigAction }
    & { read cmd: (command: "center-visible-columns") -> ConfigAction }
    & { read cmd: (command: "move", direction: "left" | "right" | "up" | "down") -> ConfigAction }
    & { read cmd: (command: "move-window-down") -> ConfigAction }
    & { read cmd: (command: "move-window-up") -> ConfigAction }
    & { read cmd: (command: "move-window-down-or-to-workspace-down") -> ConfigAction }
    & { read cmd: (command: "move-window-up-or-to-workspace-up") -> ConfigAction }
    & { read cmd: (command: "consume-or-expel-window-left") -> ConfigAction }
    & { read cmd: (command: "consume-or-expel-window-right") -> ConfigAction }
    & { read cmd: (command: "consume-window-into-column") -> ConfigAction }
    & { read cmd: (command: "expel-window-from-column") -> ConfigAction }
    & { read cmd: (command: "switch-workspace", workspace_number: string) -> ConfigAction }
    & { read cmd: (command: "switch-workspace", word2: "next") -> ConfigAction }
    & { read cmd: (command: "switch-workspace", word2: "prev") -> ConfigAction }
    & { read cmd: (command: "switch-workspace", word2: "back-and-forth") -> ConfigAction }
    & { read cmd: (command: "switch-workspace", word2: "anywhere", workspace_number: string) -> ConfigAction }
    & { read cmd: (command: "switch-workspace", word2: "slot", workspace_number: string) -> ConfigAction }
    & { read cmd: (command: "move-to-workspace", workspace_number: string) -> ConfigAction }
    & { read cmd: (command: "move-to-workspace", word2: "up") -> ConfigAction }
    & { read cmd: (command: "move-to-workspace", word2: "down") -> ConfigAction }
    & { read cmd: (command: "move-to-workspace", word2: "on-monitor", workspace_number: string, direction: "left" | "right" | "up" | "down") -> ConfigAction }
    & { read cmd: (command: "move-to-workspace", word2: "slot", workspace_number: string) -> ConfigAction }
    & { read cmd: (command: "move-to-monitor", direction: "left" | "right" | "up" | "down") -> ConfigAction }
    & { read cmd: (command: "focus-monitor", word2: "prev") -> ConfigAction }
    & { read cmd: (command: "focus-monitor", word2: "next") -> ConfigAction }
    & { read cmd: (command: "focus-monitor", word2: "last") -> ConfigAction }
    & { read cmd: (command: "move-column", direction: "left" | "right" | "up" | "down") -> ConfigAction }
    & { read cmd: (command: "move-column-to-first") -> ConfigAction }
    & { read cmd: (command: "move-column-to-last") -> ConfigAction }
    & { read cmd: (command: "move-column-to-index", column_index: string) -> ConfigAction }
    & { read cmd: (command: "move-column-to-workspace", workspace_number: string) -> ConfigAction }
    & { read cmd: (command: "move-column-to-workspace", word2: "up") -> ConfigAction }
    & { read cmd: (command: "move-column-to-workspace", word2: "down") -> ConfigAction }
    & { read cmd: (command: "toggle-column-tabbed") -> ConfigAction }
    & { read cmd: (command: "cycle-size", word2: "forward") -> ConfigAction }
    & { read cmd: (command: "cycle-size", word2: "backward") -> ConfigAction }
    & { read cmd: (command: "cycle-window-primary-span", word2: "forward") -> ConfigAction }
    & { read cmd: (command: "cycle-window-primary-span", word2: "backward") -> ConfigAction }
    & { read cmd: (command: "cycle-window-secondary-span", word2: "forward") -> ConfigAction }
    & { read cmd: (command: "cycle-window-secondary-span", word2: "backward") -> ConfigAction }
    & { read cmd: (command: "toggle-container-full-primary-span") -> ConfigAction }
    & { read cmd: (command: "expand-container-to-available-primary-span") -> ConfigAction }
    & { read cmd: (command: "reset-window-secondary-span") -> ConfigAction }
    & { read cmd: (command: "set-container-primary-span", size_change: string) -> ConfigAction }
    & { read cmd: (command: "set-window-primary-span", size_change: string) -> ConfigAction }
    & { read cmd: (command: "set-window-secondary-span", size_change: string) -> ConfigAction }
    & { read cmd: (command: "swap-workspace-with-monitor", direction: "left" | "right" | "up" | "down") -> ConfigAction }
    & { read cmd: (command: "balance-sizes") -> ConfigAction }
    & { read cmd: (command: "move-to-root") -> ConfigAction }
    & { read cmd: (command: "toggle-split") -> ConfigAction }
    & { read cmd: (command: "swap-split") -> ConfigAction }
    & { read cmd: (command: "resize", resize_axis: "horizontal" | "vertical", resize_operation: "grow" | "shrink") -> ConfigAction }
    & { read cmd: (command: "resize-focused", resize_operation: "grow" | "shrink") -> ConfigAction }
    & { read cmd: (command: "preselect", direction: "left" | "right" | "up" | "down") -> ConfigAction }
    & { read cmd: (command: "preselect", word2: "clear") -> ConfigAction }
    & { read cmd: (command: "open-command-palette") -> ConfigAction }
    & { read cmd: (command: "open-command-palette", palette_mode: "windows" | "menu" | "clipboard" | "commands" | "applications" | "files") -> ConfigAction }
    & { read cmd: (command: "window-switcher", switcher_direction: "next" | "previous") -> ConfigAction }
    & { read cmd: (command: "window-switcher", switcher_direction: "next" | "previous", switcher_scope: "active-workspace" | "visible-workspaces" | "all-workspaces") -> ConfigAction }
    & { read cmd: (command: "raise-all-floating-windows") -> ConfigAction }
    & { read cmd: (command: "toggle-floating-focus") -> ConfigAction }
    & { read cmd: (command: "rescue-offscreen-windows") -> ConfigAction }
    & { read cmd: (command: "toggle-focused-window-floating") -> ConfigAction }
    & { read cmd: (command: "close-focused-window") -> ConfigAction }
    & { read cmd: (command: "scratchpad", word2: "assign", scratchpad_index: "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "10") -> ConfigAction }
    & { read cmd: (command: "scratchpad", word2: "toggle", scratchpad_index: "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "10") -> ConfigAction }
    & { read cmd: (command: "open-menu-anywhere") -> ConfigAction }
    & { read cmd: (command: "toggle-workspace-bar") -> ConfigAction }
    & { read cmd: (command: "hidden-bar", word2: "panel") -> ConfigAction }
    & { read cmd: (command: "toggle-quake-terminal") -> ConfigAction }
    & { read cmd: (command: "toggle-workspace-layout") -> ConfigAction }
    & { read cmd: (command: "set-workspace-layout", layout: "default" | "niri" | "dwindle") -> ConfigAction }
    & { read cmd: (command: "toggle-fullscreen") -> ConfigAction }
    & { read cmd: (command: "toggle-native-fullscreen") -> ConfigAction }
    & { read cmd: (command: "toggle-overview") -> ConfigAction }
    & { read cmd: (command: "toggle-system-stats") -> ConfigAction }
    & { read cmd: (command: "volume-up") -> ConfigAction }
    & { read cmd: (command: "volume-down") -> ConfigAction }
    & { read cmd: (command: "volume-mute") -> ConfigAction }
    & { read cmd: (command: "media-play-pause") -> ConfigAction }
    & { read cmd: (command: "media-next") -> ConfigAction }
    & { read cmd: (command: "media-previous") -> ConfigAction }
    & { read cmd: (command: "toggle-shortcut-pause") -> ConfigAction }
    & { read cmd: (command: "begin-prefix") -> ConfigAction }
    & { read cmd: (command: "toggle-window-mode") -> ConfigAction }
    & { read cmd: (command: "exit-keyboard-mode") -> ConfigAction }
    & { read cmd: (command: "app-open", app_id: string) -> ConfigAction }
    & { read cmd: (command: "app-new-window", app_id: string) -> ConfigAction }

export type ConfigDispatch =
    { read dispatch: (action: ConfigAction) -> () }
    & { read dispatch: (kind: "window", action: "focus", id: string) -> () }
    & { read dispatch: (kind: "window", action: "navigate", id: string) -> () }
    & { read dispatch: (kind: "window", action: "summon-right", id: string) -> () }
    & { read dispatch: (kind: "window", action: "close", id: string) -> () }
    & { read dispatch: (kind: "window", action: "move-to-workspace", id: string, workspace: string) -> () }
    & { read dispatch: (kind: "window", action: "move-column-to-first", id: string) -> () }
    & { read dispatch: (kind: "window", action: "move-column-to-last", id: string) -> () }
    & { read dispatch: (kind: "window", action: "move-column-to-index", id: string, number: string) -> () }
    & { read dispatch: (kind: "window", action: "move-column", id: string, direction: "left" | "right" | "up" | "down") -> () }
    & { read dispatch: (kind: "window", action: "toggle-container-full-primary-span", id: string) -> () }
    & { read dispatch: (kind: "window", action: "set-container-primary-span", id: string, size_change: string) -> () }
    & { read dispatch: (kind: "window", action: "set-window-primary-span", id: string, size_change: string) -> () }
    & { read dispatch: (kind: "window", action: "cycle-window-primary-span", id: string, direction: "forward" | "backward") -> () }
    & { read dispatch: (kind: "window", action: "set-window-secondary-span", id: string, size_change: string) -> () }
    & { read dispatch: (kind: "window", action: "reset-window-secondary-span", id: string) -> () }
    & { read dispatch: (kind: "window", action: "cycle-window-secondary-span", id: string, direction: "forward" | "backward") -> () }
    & { read dispatch: (kind: "window", action: "toggle-column-tabbed", id: string) -> () }
    & { read dispatch: (kind: "window", action: "toggle-floating", id: string) -> () }
    & { read dispatch: (kind: "window", action: "assign-to-scratchpad", id: string, number: string) -> () }
export type ConfigKeymap = { read set: (chord: string, action: ConfigAction | ConfigFunction, options: { modeKey: string?, reads: { ConfigRead }? }?) -> () }
export type ConfigTimers = { read timer: (options: ConfigTimerOptions, callback: () -> ()) -> ConfigTimer }
    & { read timer: (options: ConfigTimerOptions, callback: ConfigFunction, optionsForCallback: ConfigReadOptions) -> ConfigTimer }

declare omniwm: ConfigCommands & ConfigDispatch & ConfigEvents & ConfigTimers & {
    read command: (name: string, callback: ConfigFunction, options: ConfigReadOptions?) -> (),
    read open: (bundleId: string) -> ConfigAction,
    read run: (argv: { string }) -> ConfigAction,
    read notify: (text: string) -> ConfigAction,
    read keymap: ConfigKeymap,
    read log: (...any) -> (),
    read rule: (rule: ConfigRule) -> (),
}
