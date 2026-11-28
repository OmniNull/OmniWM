// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public enum IPCCommand: Equatable, Sendable {
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

    package init(
        name: IPCCommandName,
        argumentValues: consuming[IPCCommandArgumentValue]
    ) throws(IPCCommandRequestConstructionError) {
        let arguments = IPCCommandArgumentSource(values: consume argumentValues)
        switch name {
        case let .focus(name):
            self = try .focus(IPCFocusCommand(name: name, arguments: arguments))
        case let .windowMovement(name):
            self = try .windowMovement(IPCWindowMovementCommand(name: name, arguments: arguments))
        case let .workspace(name):
            self = try .workspace(IPCWorkspaceCommand(name: name, arguments: arguments))
        case let .monitorFocus(name):
            self = try .monitorFocus(arguments.requireNoArguments(name))
        case let .column(name):
            self = try .column(IPCColumnCommand(name: name, arguments: arguments))
        case let .sizing(name):
            self = try .sizing(IPCSizingCommand(name: name, arguments: arguments))
        case .swapWorkspaceWithMonitor:
            self = try .swapWorkspaceWithMonitor(direction: arguments.direction())
        case let .dwindle(name):
            self = try .dwindle(IPCDwindleCommand(name: name, arguments: arguments))
        case .openCommandPalette: self = try arguments.requireNoArguments(.openCommandPalette)
        case .openCommandPaletteMode:
            self = try .openCommandPaletteMode(mode: arguments.paletteMode())
        case .windowSwitcher:
            self = try arguments.windowSwitcher()
        case .raiseAllFloatingWindows: self = try arguments.requireNoArguments(.raiseAllFloatingWindows)
        case .toggleFloatingFocus: self = try arguments.requireNoArguments(.toggleFloatingFocus)
        case .rescueOffscreenWindows: self = try arguments.requireNoArguments(.rescueOffscreenWindows)
        case let .workspaceLayout(name):
            self = try .workspaceLayout(IPCWorkspaceLayoutCommand(name: name, arguments: arguments))
        case let .fullscreen(name):
            self = try .fullscreen(arguments.requireNoArguments(name))
        case let .presentation(name):
            self = try .presentation(arguments.requireNoArguments(name))
        case let .media(name):
            self = try .media(arguments.requireNoArguments(name))
        case let .keyboardMode(name):
            self = try .keyboardMode(arguments.requireNoArguments(name))
        case let .windowState(name):
            self = try .windowState(arguments.requireNoArguments(name))
        case let .scratchpad(name):
            self = try .scratchpad(IPCScratchpadCommand(name: name, arguments: arguments))
        case .openMenuAnywhere: self = try arguments.requireNoArguments(.openMenuAnywhere)
        case .openSettings: self = try arguments.requireNoArguments(.openSettings)
        case .shellAppOpen:
            self = try .shellAppOpen(appID: arguments.appID())
        case .shellAppNewWindow:
            self = try .shellAppNewWindow(appID: arguments.appID())
        }
    }
}
