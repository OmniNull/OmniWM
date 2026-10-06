// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

extension IPCCommandRequest: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: IPCCommandArgumentSource.CodingKeys.self)
        let name = try container.decode(IPCCommandName.self, forKey: .name)
        try self.init(name: name, arguments: .json(container))
    }

    public func encode(to encoder: Encoder) throws {
        var writer = try IPCCommandArgumentWriter(encoder: encoder, name: name.rawValue)
        switch self {
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
             .windowState,
             .openMenuAnywhere:
            break
        }
    }
}
