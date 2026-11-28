// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public enum IPCDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case left
    case right
    case up
    case down
}

public enum IPCResizeAxis: String, Codable, CaseIterable, Equatable, Sendable {
    case horizontal
    case vertical
}

public enum IPCWorkspaceLayout: String, Codable, CaseIterable, Equatable, Sendable {
    case defaultLayout = "default"
    case niri
    case dwindle
}

public enum IPCWindowSwitcherDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case next
    case previous
}

public enum IPCWindowSwitcherScope: String, Codable, CaseIterable, Equatable, Sendable {
    case activeWorkspace = "active-workspace"
    case visibleWorkspaces = "visible-workspaces"
    case allWorkspaces = "all-workspaces"
}

public enum IPCCommandPaletteMode: String, Codable, CaseIterable, Equatable, Sendable {
    case windows
    case menu
    case clipboard
    case commands
    case applications
    case files
}

public enum IPCResizeOperation: String, Codable, CaseIterable, Equatable, Sendable {
    case grow
    case shrink
}

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
    case appID(String)
    case integer(Int)
    case layout(IPCWorkspaceLayout)
    case paletteMode(IPCCommandPaletteMode)
    case switcherDirection(IPCWindowSwitcherDirection)
    case switcherScope(IPCWindowSwitcherScope)
    case resizeAxis(IPCResizeAxis)
    case resizeOperation(IPCResizeOperation)
    case sizeChange(IPCSizeChange)
}

public enum IPCCommandRequestConstructionError: Error, Equatable, Sendable {
    case invalidArgumentCount
    case invalidArgumentType
}

public enum IPCCommandArgumentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case appID = "app-id"
    case direction
    case workspaceNumber = "workspace-number"
    case columnIndex = "column-index"
    case windowIndex = "window-index"
    case scratchpadIndex = "scratchpad-index"
    case visibleContainerCount = "visible-container-count"
    case layout
    case paletteMode = "palette-mode"
    case switcherDirection = "switcher-direction"
    case switcherScope = "switcher-scope"
    case resizeAxis = "resize-axis"
    case resizeOperation = "resize-operation"
    case sizeChange = "size-change"

    public var literalValues: [String]? {
        switch self {
        case .direction: IPCDirection.allCases.map(\.rawValue)
        case .layout: IPCWorkspaceLayout.allCases.map(\.rawValue)
        case .paletteMode: IPCCommandPaletteMode.allCases.map(\.rawValue)
        case .switcherDirection: IPCWindowSwitcherDirection.allCases.map(\.rawValue)
        case .switcherScope: IPCWindowSwitcherScope.allCases.map(\.rawValue)
        case .resizeAxis: IPCResizeAxis.allCases.map(\.rawValue)
        case .resizeOperation: IPCResizeOperation.allCases.map(\.rawValue)
        case .scratchpadIndex: IPCScratchpadSlots.range.map(String.init)
        case .visibleContainerCount: IPCVisibleContainerCounts.range.map(String.init)
        case .appID,
             .workspaceNumber,
             .columnIndex,
             .windowIndex,
             .sizeChange: nil
        }
    }
}
