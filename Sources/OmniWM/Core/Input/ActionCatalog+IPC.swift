// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMIPC

extension ActionCatalog {
    static func ipcCommandName(for command: HotkeyCommand) -> IPCCommandName? {
        switch command {
        case .focus: .focus(.spatial)
        case .move: .windowMovement(.spatial)
        case let .monitorFocus(command): .monitorFocus(command)
        case .moveColumn: .column(.move)
        case .openCommandPalette: .openCommandPalette
        case .openCommandPaletteMode: .openCommandPaletteMode
        case .raiseAllFloatingWindows: .raiseAllFloatingWindows
        case .toggleFloatingFocus: .toggleFloatingFocus
        case .rescueOffscreenWindows: .rescueOffscreenWindows
        case let .fullscreen(command): .fullscreen(command)
        case let .presentation(command): .presentation(command)
        case let .media(command): .media(command)
        case let .keyboardMode(command): .keyboardMode(command)
        case .shellToggle,
             .openApp,
             .windowMark:
            nil
        case .shellAppOpen: .shellAppOpen
        case .shellAppNewWindow: .shellAppNewWindow
        case let .windowState(command): .windowState(command)
        case .openMenuAnywhere: .openMenuAnywhere
        case let .focusNavigation(action): action.ipcCommandName()
        case let .windowMovement(action): action.ipcCommandName()
        case let .column(action): action.ipcCommandName()
        case let .workspace(action): action.ipcCommandName()
        case let .sizing(action): action.ipcCommandName()
        case let .dwindle(action): action.ipcCommandName()
        case let .scratchpad(action): action.ipcCommandName()
        }
    }
}
