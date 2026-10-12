// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum IPCCommandIntegerField {
    case workspaceNumber
    case slotNumber
    case columnIndex
    case scratchpadIndex
    case windowIndex
}

enum IPCCommandArgumentSource {
    enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }

    case values([IPCCommandArgumentValue])
    case json(KeyedDecodingContainer<CodingKeys>)

    func requireNoArguments<Value>(_ value: Value) throws -> Value {
        if case let .values(arguments) = self, !arguments.isEmpty {
            throw IPCCommandRequestConstructionError.invalidArgumentCount
        }
        return value
    }

    func direction() throws -> IPCDirection {
        switch self {
        case let .values(arguments):
            guard arguments.count == 1, case let .direction(value) = arguments[0] else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return value
        case let .json(container):
            return try container.decode(IPCDirectionArguments.self, forKey: .arguments).direction
        }
    }

    func layout() throws -> IPCWorkspaceLayout {
        switch self {
        case let .values(arguments):
            guard arguments.count == 1, case let .layout(value) = arguments[0] else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return value
        case let .json(container):
            return try container.decode(IPCLayoutArguments.self, forKey: .arguments).layout
        }
    }

    func paletteMode() throws -> IPCCommandPaletteMode {
        switch self {
        case let .values(arguments):
            guard arguments.count == 1, case let .paletteMode(value) = arguments[0] else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return value
        case let .json(container):
            return try container.decode(IPCPaletteModeArguments.self, forKey: .arguments).mode
        }
    }

    func sizeChange() throws -> IPCSizeChange {
        switch self {
        case let .values(arguments):
            guard arguments.count == 1, case let .sizeChange(value) = arguments[0] else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return value
        case let .json(container):
            return try container.decode(IPCSizeChangeArguments.self, forKey: .arguments).change
        }
    }

    func resizeOperation() throws -> IPCResizeOperation {
        switch self {
        case let .values(arguments):
            guard arguments.count == 1, case let .resizeOperation(value) = arguments[0] else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return value
        case let .json(container):
            return try container.decode(IPCResizeOperationArguments.self, forKey: .arguments).operation
        }
    }

    func integer(_ field: IPCCommandIntegerField) throws -> Int {
        switch self {
        case let .values(arguments):
            guard arguments.count == 1, case let .integer(value) = arguments[0] else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return value
        case let .json(container):
            switch field {
            case .workspaceNumber:
                return try container.decode(IPCWorkspaceNumberArguments.self, forKey: .arguments).workspaceNumber
            case .slotNumber:
                return try container.decode(IPCSlotNumberArguments.self, forKey: .arguments).slotNumber
            case .columnIndex:
                return try container.decode(IPCColumnIndexArguments.self, forKey: .arguments).columnIndex
            case .scratchpadIndex:
                return try container.decode(IPCScratchpadIndexArguments.self, forKey: .arguments).scratchpadIndex
            case .windowIndex:
                return try container.decode(IPCWindowIndexArguments.self, forKey: .arguments).windowIndex
            }
        }
    }

    func workspaceAndDirection() throws -> (workspaceNumber: Int, direction: IPCDirection) {
        switch self {
        case let .values(arguments):
            guard arguments.count == 2,
                  case let .integer(workspaceNumber) = arguments[0],
                  case let .direction(direction) = arguments[1]
            else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return (workspaceNumber, direction)
        case let .json(container):
            let arguments = try container.decode(IPCWorkspaceOnMonitorArguments.self, forKey: .arguments)
            return (arguments.workspaceNumber, arguments.direction)
        }
    }

    func resize() throws -> (axis: IPCResizeAxis, operation: IPCResizeOperation) {
        switch self {
        case let .values(arguments):
            guard arguments.count == 2,
                  case let .resizeAxis(axis) = arguments[0],
                  case let .resizeOperation(operation) = arguments[1]
            else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            return (axis, operation)
        case let .json(container):
            let arguments = try container.decode(IPCResizeArguments.self, forKey: .arguments)
            return (arguments.axis, arguments.operation)
        }
    }
}

struct IPCCommandArgumentWriter {
    private var container: KeyedEncodingContainer<IPCCommandArgumentSource.CodingKeys>

    init(encoder: Encoder, name: String) throws {
        container = encoder.container(keyedBy: IPCCommandArgumentSource.CodingKeys.self)
        try container.encode(name, forKey: .name)
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
