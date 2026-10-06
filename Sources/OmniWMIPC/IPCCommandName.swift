// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

public enum IPCCommandName: RawRepresentable, Codable, CaseIterable, Hashable, Sendable {
    case focus(IPCFocusCommandName)
    case windowMovement(IPCWindowMovementCommandName)
    case workspace(IPCWorkspaceCommandName)
    case monitorFocus(IPCMonitorFocusCommand)
    case column(IPCColumnCommandName)
    case sizing(IPCSizingCommandName)
    case swapWorkspaceWithMonitor
    case dwindle(IPCDwindleCommandName)
    case openCommandPalette
    case openCommandPaletteMode
    case raiseAllFloatingWindows
    case rescueOffscreenWindows
    case workspaceLayout(IPCWorkspaceLayoutCommandName)
    case fullscreen(IPCFullscreenCommand)
    case presentation(IPCPresentationCommand)
    case windowState(IPCWindowStateCommand)
    case scratchpad(IPCScratchpadCommandName)
    case openMenuAnywhere

    public var rawValue: String {
        switch self {
        case let .focus(name):
            name.rawValue
        case let .windowMovement(name):
            name.rawValue
        case let .workspace(name):
            name.rawValue
        case let .monitorFocus(name):
            name.rawValue
        case let .column(name):
            name.rawValue
        case let .sizing(name):
            name.rawValue
        case .swapWorkspaceWithMonitor:
            "swap-workspace-with-monitor"
        case let .dwindle(name):
            name.rawValue
        case .openCommandPalette:
            "open-command-palette"
        case .openCommandPaletteMode:
            "open-command-palette-mode"
        case .raiseAllFloatingWindows:
            "raise-all-floating-windows"
        case .rescueOffscreenWindows:
            "rescue-offscreen-windows"
        case let .workspaceLayout(name):
            name.rawValue
        case let .fullscreen(name):
            name.rawValue
        case let .presentation(name):
            name.rawValue
        case let .windowState(name):
            name.rawValue
        case let .scratchpad(name):
            name.rawValue
        case .openMenuAnywhere:
            "open-menu-anywhere"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "swap-workspace-with-monitor":
            self = .swapWorkspaceWithMonitor
        case "open-command-palette":
            self = .openCommandPalette
        case "open-command-palette-mode":
            self = .openCommandPaletteMode
        case "raise-all-floating-windows":
            self = .raiseAllFloatingWindows
        case "rescue-offscreen-windows":
            self = .rescueOffscreenWindows
        case "open-menu-anywhere":
            self = .openMenuAnywhere
        default:
            var name = IPCFocusCommandName(rawValue: rawValue).map(Self.focus)
            name = name ?? IPCWindowMovementCommandName(rawValue: rawValue).map(Self.windowMovement)
            name = name ?? IPCWorkspaceCommandName(rawValue: rawValue).map(Self.workspace)
            name = name ?? IPCMonitorFocusCommand(rawValue: rawValue).map(Self.monitorFocus)
            name = name ?? IPCColumnCommandName(rawValue: rawValue).map(Self.column)
            name = name ?? IPCSizingCommandName(rawValue: rawValue).map(Self.sizing)
            name = name ?? IPCDwindleCommandName(rawValue: rawValue).map(Self.dwindle)
            name = name ?? IPCWorkspaceLayoutCommandName(rawValue: rawValue).map(Self.workspaceLayout)
            name = name ?? IPCFullscreenCommand(rawValue: rawValue).map(Self.fullscreen)
            name = name ?? IPCPresentationCommand(rawValue: rawValue).map(Self.presentation)
            name = name ?? IPCWindowStateCommand(rawValue: rawValue).map(Self.windowState)
            name = name ?? IPCScratchpadCommandName(rawValue: rawValue).map(Self.scratchpad)
            guard let name else { return nil }
            self = name
        }
    }

    public static var allCases: [IPCCommandName] {
        var names: [IPCCommandName] = []
        names.append(contentsOf: IPCFocusCommandName.allCases.map(Self.focus))
        names.append(contentsOf: IPCWindowMovementCommandName.allCases.map(Self.windowMovement))
        names.append(contentsOf: IPCWorkspaceCommandName.allCases.map(Self.workspace))
        names.append(contentsOf: IPCMonitorFocusCommand.allCases.map(Self.monitorFocus))
        names.append(contentsOf: IPCColumnCommandName.allCases.map(Self.column))
        names.append(contentsOf: IPCSizingCommandName.allCases.map(Self.sizing))
        names.append(.swapWorkspaceWithMonitor)
        names.append(contentsOf: IPCDwindleCommandName.allCases.map(Self.dwindle))
        names.append(.openCommandPalette)
        names.append(.openCommandPaletteMode)
        names.append(.raiseAllFloatingWindows)
        names.append(.rescueOffscreenWindows)
        names.append(contentsOf: IPCWorkspaceLayoutCommandName.allCases.map(Self.workspaceLayout))
        names.append(contentsOf: IPCFullscreenCommand.allCases.map(Self.fullscreen))
        names.append(contentsOf: IPCPresentationCommand.allCases.map(Self.presentation))
        names.append(contentsOf: IPCWindowStateCommand.allCases.map(Self.windowState))
        names.append(contentsOf: IPCScratchpadCommandName.allCases.map(Self.scratchpad))
        names.append(.openMenuAnywhere)
        return names
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let name = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot initialize IPCCommandName from invalid String value \(rawValue)"
            )
        }
        self = name
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
