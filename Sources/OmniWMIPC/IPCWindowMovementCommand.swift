// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation

extension IPCWindowMovementCommand {
    func encodeArguments(to writer: inout IPCCommandArgumentWriter) throws {
        switch self {
        case let .spatial(direction):
            try writer.encode(direction: direction)
        case .down,
             .up,
             .downOrToWorkspaceDown,
             .upOrToWorkspaceUp,
             .consumeOrExpelLeft,
             .consumeOrExpelRight,
             .consumeIntoColumn,
             .expelFromColumn:
            break
        }
    }
}
