// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

extension IPCCommandRequest {
    public init(name: IPCCommandName, argumentValues: [IPCCommandArgumentValue] = []) throws {
        try self.init(name: name, arguments: .values(argumentValues))
    }

    init(name: IPCCommandName, arguments: IPCCommandArgumentSource) throws {
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
        case .openCommandPalette:
            self = try arguments.requireNoArguments(.openCommandPalette)
        case .openCommandPaletteMode:
            self = try .openCommandPaletteMode(mode: arguments.paletteMode())
        case .raiseAllFloatingWindows:
            self = try arguments.requireNoArguments(.raiseAllFloatingWindows)
        case .toggleFloatingFocus:
            self = try arguments.requireNoArguments(.toggleFloatingFocus)
        case .rescueOffscreenWindows:
            self = try arguments.requireNoArguments(.rescueOffscreenWindows)
        case let .workspaceLayout(name):
            self = try .workspaceLayout(IPCWorkspaceLayoutCommand(name: name, arguments: arguments))
        case let .fullscreen(name):
            self = try .fullscreen(arguments.requireNoArguments(name))
        case let .presentation(name):
            self = try .presentation(arguments.requireNoArguments(name))
        case let .windowState(name):
            self = try .windowState(arguments.requireNoArguments(name))
        case let .scratchpad(name):
            self = try .scratchpad(IPCScratchpadCommand(name: name, arguments: arguments))
        case .openMenuAnywhere:
            self = try arguments.requireNoArguments(.openMenuAnywhere)
        }
    }
}
