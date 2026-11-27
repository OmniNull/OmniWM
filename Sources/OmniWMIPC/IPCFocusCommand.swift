// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation

extension IPCFocusCommand {
    func encodeArguments(to writer: inout IPCCommandArgumentWriter) throws {
        switch self {
        case let .spatial(direction):
            try writer.encode(direction: direction)
        case let .windowInColumn(windowIndex):
            try writer.encode(integer: windowIndex, field: .windowIndex)
        case let .column(columnIndex):
            try writer.encode(integer: columnIndex, field: .columnIndex)
        case .previous,
             .downOrLeft,
             .upOrRight,
             .windowTop,
             .windowBottom,
             .windowDownOrTop,
             .windowUpOrBottom,
             .windowOrWorkspaceDown,
             .windowOrWorkspaceUp,
             .columnFirst,
             .columnLast,
             .centerColumn,
             .centerVisibleColumns:
            break
        }
    }
}
