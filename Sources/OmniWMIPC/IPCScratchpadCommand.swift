// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation

extension IPCScratchpadCommand {
    func encodeArguments(to writer: inout IPCCommandArgumentWriter) throws {
        switch self {
        case let .assign(index):
            try writer.encode(integer: index, field: .scratchpadIndex)
        case let .toggle(index):
            try writer.encode(integer: index, field: .scratchpadIndex)
        }
    }
}
