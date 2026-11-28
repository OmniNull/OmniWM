// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMAutomation

enum IPCCommandIntegerField {
    case workspaceNumber
    case slotNumber
    case columnIndex
    case scratchpadIndex
    case windowIndex
    case visibleContainerCount
}

enum IPCCommandCodingKeys: String, CodingKey {
    case name
    case arguments
}

extension KeyedDecodingContainer where Key == IPCCommandCodingKeys {
    func commandArguments(for name: IPCCommandName) throws -> [IPCCommandArgumentValue] {
        switch try firstArgumentKind(for: name) {
        case nil: return []
        case .appID: return try [.appID(decode(IPCAppIDArguments.self, forKey: .arguments).appId)]
        case .direction: return try [.direction(decode(IPCDirectionArguments.self, forKey: .arguments).direction)]
        case .layout: return try [.layout(decode(IPCLayoutArguments.self, forKey: .arguments).layout)]
        case .paletteMode: return try [.paletteMode(decode(IPCPaletteModeArguments.self, forKey: .arguments).mode)]
        case .switcherDirection:
            let values = try decode(IPCWindowSwitcherArguments.self, forKey: .arguments)
            var arguments: [IPCCommandArgumentValue] = [.switcherDirection(values.direction)]
            if let scope = values.scope {
                arguments.append(.switcherScope(scope))
            }
            return arguments
        case .resizeAxis:
            let values = try decode(IPCResizeArguments.self, forKey: .arguments)
            return [.resizeAxis(values.axis), .resizeOperation(values.operation)]
        case .resizeOperation:
            return try [.resizeOperation(decode(IPCResizeOperationArguments.self, forKey: .arguments).operation)]
        case .sizeChange: return try [.sizeChange(decode(IPCSizeChangeArguments.self, forKey: .arguments).change)]
        case .workspaceNumber: return try workspaceArguments(for: name)
        case .columnIndex: return try [.integer(decode(IPCColumnIndexArguments.self, forKey: .arguments).columnIndex)]
        case .windowIndex: return try [.integer(decode(IPCWindowIndexArguments.self, forKey: .arguments).windowIndex)]
        case .scratchpadIndex:
            return try [.integer(decode(IPCScratchpadIndexArguments.self, forKey: .arguments).scratchpadIndex)]
        case .visibleContainerCount:
            return try [.integer(decode(IPCVisibleContainerCountArguments.self, forKey: .arguments)
                    .visibleContainerCount)]
        case .switcherScope: throw IPCCommandRequestConstructionError.invalidArgumentType
        }
    }

    private func firstArgumentKind(for name: IPCCommandName) throws -> IPCCommandArgumentKind? {
        let forms = IPCCommandForm.all
        for index in forms.indices where forms[index].name == name {
            return forms[index].arguments.first
        }
        throw IPCCommandRequestConstructionError.invalidArgumentType
    }

    private func workspaceArguments(for name: IPCCommandName) throws -> [IPCCommandArgumentValue] {
        switch name {
        case .workspace(.switchSlot),
             .workspace(.moveToSlot):
            return try [.integer(decode(IPCSlotNumberArguments.self, forKey: .arguments).slotNumber)]
        case .workspace(.moveToOnMonitor):
            let values = try decode(IPCWorkspaceOnMonitorArguments.self, forKey: .arguments)
            return [.integer(values.workspaceNumber), .direction(values.direction)]
        default:
            return try [.integer(decode(IPCWorkspaceNumberArguments.self, forKey: .arguments).workspaceNumber)]
        }
    }
}

struct IPCCommandArgumentWriter {
    private var container: KeyedEncodingContainer<IPCCommandCodingKeys>

    init(encoder: Encoder, name: String) throws {
        container = encoder.container(keyedBy: IPCCommandCodingKeys.self)
        try container.encode(name, forKey: .name)
    }

    mutating func encode(appID value: String) throws {
        try container.encode(IPCAppIDArguments(appId: value), forKey: .arguments)
    }

    mutating func encode(direction value: IPCDirection) throws {
        try container.encode(IPCDirectionArguments(direction: value), forKey: .arguments)
    }

    mutating func encode(layout value: IPCWorkspaceLayout) throws {
        try container.encode(IPCLayoutArguments(layout: value), forKey: .arguments)
    }

    mutating func encode(paletteMode value: IPCCommandPaletteMode) throws {
        try container.encode(IPCPaletteModeArguments(mode: value), forKey: .arguments)
    }

    mutating func encode(
        switcherDirection direction: IPCWindowSwitcherDirection,
        scope: IPCWindowSwitcherScope?
    ) throws {
        try container.encode(IPCWindowSwitcherArguments(direction: direction, scope: scope), forKey: .arguments)
    }

    mutating func encode(sizeChange value: IPCSizeChange) throws {
        try container.encode(IPCSizeChangeArguments(change: value), forKey: .arguments)
    }

    mutating func encode(resizeOperation value: IPCResizeOperation) throws {
        try container.encode(IPCResizeOperationArguments(operation: value), forKey: .arguments)
    }

    mutating func encode(integer value: Int, field: IPCCommandIntegerField) throws {
        switch field {
        case .workspaceNumber:
            try container.encode(IPCWorkspaceNumberArguments(workspaceNumber: value), forKey: .arguments)
        case .slotNumber:
            try container.encode(IPCSlotNumberArguments(slotNumber: value), forKey: .arguments)
        case .columnIndex:
            try container.encode(IPCColumnIndexArguments(columnIndex: value), forKey: .arguments)
        case .scratchpadIndex:
            try container.encode(IPCScratchpadIndexArguments(scratchpadIndex: value), forKey: .arguments)
        case .windowIndex:
            try container.encode(IPCWindowIndexArguments(windowIndex: value), forKey: .arguments)
        case .visibleContainerCount:
            try container.encode(IPCVisibleContainerCountArguments(visibleContainerCount: value), forKey: .arguments)
        }
    }

    mutating func encode(workspaceNumber: Int, direction: IPCDirection) throws {
        try container.encode(
            IPCWorkspaceOnMonitorArguments(workspaceNumber: workspaceNumber, direction: direction),
            forKey: .arguments
        )
    }

    mutating func encode(axis: IPCResizeAxis, operation: IPCResizeOperation) throws {
        try container.encode(IPCResizeArguments(axis: axis, operation: operation), forKey: .arguments)
    }
}

private struct IPCAppIDArguments: Codable, Equatable, Sendable {
    let appId: String
}

private struct IPCDirectionArguments: Codable, Equatable, Sendable {
    let direction: IPCDirection
}

private struct IPCWorkspaceNumberArguments: Codable, Equatable, Sendable {
    let workspaceNumber: Int
}

private struct IPCSlotNumberArguments: Codable, Equatable, Sendable {
    let slotNumber: Int
}

private struct IPCColumnIndexArguments: Codable, Equatable, Sendable {
    let columnIndex: Int
}

private struct IPCScratchpadIndexArguments: Codable, Equatable, Sendable {
    let scratchpadIndex: Int
}

private struct IPCWindowIndexArguments: Codable, Equatable, Sendable {
    let windowIndex: Int
}

private struct IPCWorkspaceOnMonitorArguments: Codable, Equatable, Sendable {
    let workspaceNumber: Int
    let direction: IPCDirection
}

private struct IPCLayoutArguments: Codable, Equatable, Sendable {
    let layout: IPCWorkspaceLayout
}

private struct IPCPaletteModeArguments: Codable, Equatable, Sendable {
    let mode: IPCCommandPaletteMode
}

private struct IPCWindowSwitcherArguments: Codable, Equatable, Sendable {
    let direction: IPCWindowSwitcherDirection
    let scope: IPCWindowSwitcherScope?
}

private struct IPCResizeArguments: Codable, Equatable, Sendable {
    let axis: IPCResizeAxis
    let operation: IPCResizeOperation
}

private struct IPCResizeOperationArguments: Codable, Equatable, Sendable {
    let operation: IPCResizeOperation
}

private struct IPCSizeChangeArguments: Codable, Equatable, Sendable {
    let change: IPCSizeChange
}

private struct IPCVisibleContainerCountArguments: Codable, Equatable, Sendable {
    let visibleContainerCount: Int
}
