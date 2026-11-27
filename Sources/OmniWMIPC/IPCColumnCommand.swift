// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation

extension IPCColumnCommand {
    func encodeArguments(to writer: inout IPCCommandArgumentWriter) throws {
        switch self {
        case let .move(direction):
            try writer.encode(direction: direction)
        case let .moveToIndex(columnIndex):
            try writer.encode(integer: columnIndex, field: .columnIndex)
        case let .moveToWorkspace(workspaceNumber):
            try writer.encode(integer: workspaceNumber, field: .workspaceNumber)
        case .moveToFirst,
             .moveToLast,
             .moveToWorkspaceUp,
             .moveToWorkspaceDown,
             .toggleTabbed:
            break
        }
    }
}
