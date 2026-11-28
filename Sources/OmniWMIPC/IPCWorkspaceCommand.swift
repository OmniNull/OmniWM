// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation

extension IPCWorkspaceCommand {
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
