// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation

extension IPCWorkspaceCommand {
    init(name: IPCWorkspaceCommandName, arguments: IPCCommandArgumentSource) throws {
        switch name {
        case .switchTo,
             .next,
             .previous,
             .backAndForth,
             .switchAnywhere,
             .switchSlot:
            try self.init(switchName: name, arguments: arguments)
        case .moveTo:
            self = try .moveTo(workspaceNumber: arguments.integer(.workspaceNumber))
        case .moveUp:
            self = try arguments.requireNoArguments(.moveUp)
        case .moveDown:
            self = try arguments.requireNoArguments(.moveDown)
        case .moveToOnMonitor:
            let values = try arguments.workspaceAndDirection()
            self = .moveToOnMonitor(workspaceNumber: values.workspaceNumber, direction: values.direction)
        case .moveToSlot:
            self = try .moveToSlot(slotNumber: arguments.integer(.slotNumber))
        case .moveToMonitor:
            self = try .moveToMonitor(direction: arguments.direction())
        }
    }

    private init(switchName: IPCWorkspaceCommandName, arguments: IPCCommandArgumentSource) throws {
        if case let .values(values) = arguments {
            try self.init(switchName: switchName, argumentValues: values)
            return
        }
        switch switchName {
        case .switchTo,
             .switchAnywhere:
            try self.init(switchName: switchName, number: arguments.integer(.workspaceNumber))
        case .switchSlot:
            try self.init(switchName: switchName, number: arguments.integer(.slotNumber))
        case .next: self = .next
        case .previous: self = .previous
        case .backAndForth: self = .backAndForth
        default: throw IPCCommandRequestConstructionError.invalidArgumentType
        }
    }

    func encodeArguments(to writer: inout IPCCommandArgumentWriter) throws {
        switch self {
        case let .switchTo(workspaceNumber):
            try writer.encode(integer: workspaceNumber, field: .workspaceNumber)
        case let .switchAnywhere(workspaceNumber):
            try writer.encode(integer: workspaceNumber, field: .workspaceNumber)
        case let .switchSlot(slotNumber):
            try writer.encode(integer: slotNumber, field: .slotNumber)
        case let .moveTo(workspaceNumber):
            try writer.encode(integer: workspaceNumber, field: .workspaceNumber)
        case let .moveToOnMonitor(workspaceNumber, direction):
            try writer.encode(workspaceNumber: workspaceNumber, direction: direction)
        case let .moveToSlot(slotNumber):
            try writer.encode(integer: slotNumber, field: .slotNumber)
        case let .moveToMonitor(direction):
            try writer.encode(direction: direction)
        case .next,
             .previous,
             .backAndForth,
             .moveUp,
             .moveDown:
            break
        }
    }
}
