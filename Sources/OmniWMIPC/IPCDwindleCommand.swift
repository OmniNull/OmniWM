// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation

extension IPCDwindleCommand {
    func encodeArguments(to writer: inout IPCCommandArgumentWriter) throws {
        switch self {
        case let .resize(axis, operation):
            try writer.encode(axis: axis, operation: operation)
        case let .resizeFocused(operation):
            try writer.encode(resizeOperation: operation)
        case let .resizeDirection(direction),
             let .preselect(direction):
            try writer.encode(direction: direction)
        case .balanceSizes,
             .moveToRoot,
             .toggleSplit,
             .swapSplit,
             .preselectClear:
            break
        }
    }
}
