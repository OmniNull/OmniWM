// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension IPCCommandRequest: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: IPCCommandArgumentSource.CodingKeys.self)
        let name = try container.decode(IPCCommandName.self, forKey: .name)
        try self.init(name: name, arguments: .json(container))
    }

    public func encode(to encoder: Encoder) throws {
        var writer = try IPCCommandArgumentWriter(encoder: encoder, name: name.rawValue)
        switch self {
        case let .shellAppOpen(appID),
             let .shellAppNewWindow(appID):
            try writer.encode(appID: appID)
        case let .focus(command):
            try command.encodeArguments(to: &writer)
        case let .windowMovement(command):
            try command.encodeArguments(to: &writer)
        case let .workspace(command):
            try command.encodeArguments(to: &writer)
        case let .column(command):
            try command.encodeArguments(to: &writer)
        case let .sizing(command):
            try command.encodeArguments(to: &writer)
        case let .swapWorkspaceWithMonitor(direction):
            try writer.encode(direction: direction)
        case let .dwindle(command):
            try command.encodeArguments(to: &writer)
        case let .openCommandPaletteMode(mode):
            try writer.encode(paletteMode: mode)
        case let .windowSwitcher(direction, scope):
            try writer.encode(switcherDirection: direction, scope: scope)
        case let .workspaceLayout(command):
            try command.encodeArguments(to: &writer)
        case let .scratchpad(command):
            try command.encodeArguments(to: &writer)
        case .monitorFocus,
             .openCommandPalette,
             .raiseAllFloatingWindows,
             .toggleFloatingFocus,
             .rescueOffscreenWindows,
             .fullscreen,
             .presentation,
             .media,
             .keyboardMode,
             .windowState,
             .openMenuAnywhere:
            break
        }
    }
}
