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

declare omniwm: ConfigCommands & {
    read keymap: { read set: (chord: string, action: ConfigAction, options: { modeKey: string? }?) -> () },
    read rule: (rule: ConfigRule) -> (),
}
