// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation

extension IPCSizingCommand {
    func encodeArguments(to writer: inout IPCCommandArgumentWriter) throws {
        switch self {
        case let .setContainerPrimarySpan(change):
            try writer.encode(sizeChange: change)
        case let .setWindowPrimarySpan(change):
            try writer.encode(sizeChange: change)
        case let .setWindowSecondarySpan(change):
            try writer.encode(sizeChange: change)
        case let .setVisibleContainers(count):
            try writer.encode(integer: count, field: .visibleContainerCount)
        case .cycleSizeForward,
             .cycleSizeBackward,
             .cycleWindowPrimarySpanForward,
             .cycleWindowPrimarySpanBackward,
             .cycleWindowSecondarySpanForward,
             .cycleWindowSecondarySpanBackward,
             .toggleContainerFullPrimarySpan,
             .expandContainerToAvailablePrimarySpan,
             .resetWindowSecondarySpan:
            break
        }
    }
}
