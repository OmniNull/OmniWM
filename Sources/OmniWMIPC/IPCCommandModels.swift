// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

public enum IPCSizeChangeKind: String, Codable, Equatable, Sendable {
    case setFixed = "set-fixed"
    case setProportion = "set-proportion"
    case adjustFixed = "adjust-fixed"
    case adjustProportion = "adjust-proportion"
}

public struct IPCSizeChange: Codable, Equatable, Sendable {
    public let kind: IPCSizeChangeKind
    public let value: Double

    public init(kind: IPCSizeChangeKind, value: Double) {
        self.kind = kind
        self.value = value
    }

    public static func setFixed(_ value: Double) -> IPCSizeChange {
        IPCSizeChange(kind: .setFixed, value: value)
    }

    public static func setProportion(_ value: Double) -> IPCSizeChange {
        IPCSizeChange(kind: .setProportion, value: value)
    }

    public static func adjustFixed(_ value: Double) -> IPCSizeChange {
        IPCSizeChange(kind: .adjustFixed, value: value)
    }

    public static func adjustProportion(_ value: Double) -> IPCSizeChange {
        IPCSizeChange(kind: .adjustProportion, value: value)
    }
}

public enum IPCCommandArgumentValue: Equatable, Sendable {
    case direction(IPCDirection)
    case integer(Int)
    case layout(IPCWorkspaceLayout)
    case paletteMode(IPCCommandPaletteMode)
    case resizeAxis(IPCResizeAxis)
    case resizeOperation(IPCResizeOperation)
    case sizeChange(IPCSizeChange)
}

public enum IPCCommandRequestConstructionError: Error, Equatable, Sendable {
    case invalidArgumentCount
    case invalidArgumentType
}

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
    case raiseAllFloatingWindows
    case rescueOffscreenWindows
    case workspaceLayout(IPCWorkspaceLayoutCommand)
    case fullscreen(IPCFullscreenCommand)
    case presentation(IPCPresentationCommand)
    case windowState(IPCWindowStateCommand)
    case scratchpad(IPCScratchpadCommand)
    case openMenuAnywhere

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
        case .raiseAllFloatingWindows:
            .raiseAllFloatingWindows
        case .rescueOffscreenWindows:
            .rescueOffscreenWindows
        case let .workspaceLayout(command):
            .workspaceLayout(command.name)
        case let .fullscreen(command):
            .fullscreen(command)
        case let .presentation(command):
            .presentation(command)
        case let .windowState(command):
            .windowState(command)
        case let .scratchpad(command):
            .scratchpad(command.name)
        case .openMenuAnywhere:
            .openMenuAnywhere
        }
    }
}
