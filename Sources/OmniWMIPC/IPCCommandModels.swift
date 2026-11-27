// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMAutomation

public enum IPCCommandRequest: Equatable, Sendable {
    case focus(IPCFocusCommand)
    case windowMovement(IPCWindowMovementCommand)
    case workspace(IPCWorkspaceCommand)
    case monitorFocus(IPCMonitorFocusCommand)
    case column(IPCColumnCommand)
    case sizing(IPCSizingCommand)
    case swapWorkspaceWithMonitor(direction: IPCDirection)
    case dwindle(IPCDwindleCommand)
    case openCommandPalette
    case openCommandPaletteMode(mode: IPCCommandPaletteMode)
    case windowSwitcher(direction: IPCWindowSwitcherDirection, scope: IPCWindowSwitcherScope?)
    case raiseAllFloatingWindows
    case toggleFloatingFocus
    case rescueOffscreenWindows
    case workspaceLayout(IPCWorkspaceLayoutCommand)
    case fullscreen(IPCFullscreenCommand)
    case presentation(IPCPresentationCommand)
    case media(IPCMediaCommand)
    case keyboardMode(IPCKeyboardModeCommand)
    case windowState(IPCWindowStateCommand)
    case scratchpad(IPCScratchpadCommand)
    case openMenuAnywhere
    case openSettings
    case shellAppOpen(appID: String)
    case shellAppNewWindow(appID: String)

    public var name: IPCCommandName {
        switch self {
        case let .focus(command):
            .focus(command.name)
        case let .windowMovement(command):
            .windowMovement(command.name)
        case let .workspace(command):
            .workspace(command.name)
        case let .monitorFocus(command):
            .monitorFocus(command)
        case let .column(command):
            .column(command.name)
        case let .sizing(command):
            .sizing(command.name)
        case .swapWorkspaceWithMonitor:
            .swapWorkspaceWithMonitor
        case let .dwindle(command):
            .dwindle(command.name)
        case .openCommandPalette:
            .openCommandPalette
        case .openCommandPaletteMode:
            .openCommandPaletteMode
        case .windowSwitcher:
            .windowSwitcher
        case .raiseAllFloatingWindows:
            .raiseAllFloatingWindows
        case .toggleFloatingFocus:
            .toggleFloatingFocus
        case .rescueOffscreenWindows:
            .rescueOffscreenWindows
        case let .workspaceLayout(command):
            .workspaceLayout(command.name)
        case let .fullscreen(command):
            .fullscreen(command)
        case let .presentation(command):
            .presentation(command)
        case let .media(command):
            .media(command)
        case let .keyboardMode(command):
            .keyboardMode(command)
        case let .windowState(command):
            .windowState(command)
        case let .scratchpad(command):
            .scratchpad(command.name)
        case .openMenuAnywhere:
            .openMenuAnywhere
        case .openSettings:
            .openSettings
        case .shellAppOpen:
            .shellAppOpen
        case .shellAppNewWindow:
            .shellAppNewWindow
        }
    }
}
