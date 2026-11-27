// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

struct IPCCommandArgumentSource {
    let values: [IPCCommandArgumentValue]

    init(values: consuming[IPCCommandArgumentValue]) {
        self.values = consume values
    }

    func requireNoArguments<Value>(_ value: Value) throws(IPCCommandRequestConstructionError) -> Value {
        guard values.isEmpty else { throw .invalidArgumentCount }
        return value
    }

    func appID() throws(IPCCommandRequestConstructionError) -> String {
        guard values.count == 1, case let .appID(appID) = values[0] else {
            throw .invalidArgumentType
        }
        guard !appID.isEmpty else { throw .invalidArgumentType }
        return appID
    }

    func direction() throws(IPCCommandRequestConstructionError) -> IPCDirection {
        guard values.count == 1, case let .direction(value) = values[0] else {
            throw .invalidArgumentType
        }
        return value
    }

    func layout() throws(IPCCommandRequestConstructionError) -> IPCWorkspaceLayout {
        guard values.count == 1, case let .layout(value) = values[0] else {
            throw .invalidArgumentType
        }
        return value
    }

    func paletteMode() throws(IPCCommandRequestConstructionError) -> IPCCommandPaletteMode {
        guard values.count == 1, case let .paletteMode(value) = values[0] else {
            throw .invalidArgumentType
        }
        return value
    }

    func windowSwitcher() throws(IPCCommandRequestConstructionError) -> IPCCommand {
        guard (1 ... 2).contains(values.count), case let .switcherDirection(direction) = values[0] else {
            throw .invalidArgumentType
        }
        guard values.count == 2 else { return .windowSwitcher(direction: direction, scope: nil) }
        guard case let .switcherScope(scope) = values[1] else {
            throw .invalidArgumentType
        }
        return .windowSwitcher(direction: direction, scope: scope)
    }

    func sizeChange() throws(IPCCommandRequestConstructionError) -> IPCSizeChange {
        guard values.count == 1, case let .sizeChange(value) = values[0] else {
            throw .invalidArgumentType
        }
        return value
    }

    func resizeOperation() throws(IPCCommandRequestConstructionError) -> IPCResizeOperation {
        guard values.count == 1, case let .resizeOperation(value) = values[0] else {
            throw .invalidArgumentType
        }
        return value
    }

    func integer() throws(IPCCommandRequestConstructionError) -> Int {
        guard values.count == 1, case let .integer(value) = values[0] else {
            throw .invalidArgumentType
        }
        return value
    }

    func workspaceAndDirection() throws(IPCCommandRequestConstructionError)
        -> (workspaceNumber: Int, direction: IPCDirection)
    {
        guard values.count == 2,
              case let .integer(workspaceNumber) = values[0],
              case let .direction(direction) = values[1]
        else {
            throw .invalidArgumentType
        }
        return (workspaceNumber, direction)
    }

    func resize() throws(IPCCommandRequestConstructionError) -> (axis: IPCResizeAxis, operation: IPCResizeOperation) {
        guard values.count == 2,
              case let .resizeAxis(axis) = values[0],
              case let .resizeOperation(operation) = values[1]
        else {
            throw .invalidArgumentType
        }
        return (axis, operation)
    }
}
