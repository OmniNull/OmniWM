// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public enum IPCScratchpadCommandName: String, CaseIterable, Hashable, Sendable {
    case assign = "scratchpad-assign"
    case toggle = "scratchpad-toggle"
}

public enum IPCScratchpadCommand: Equatable, Sendable {
    case assign(index: Int)
    case toggle(index: Int)

    public var name: IPCScratchpadCommandName {
        switch self {
        case .assign:
            .assign
        case .toggle:
            .toggle
        }
    }

    init(name: IPCScratchpadCommandName, arguments: borrowing IPCCommandArgumentSource)
        throws(IPCCommandRequestConstructionError)
    {
        switch name {
        case .assign:
            self = try .assign(index: arguments.integer())
        case .toggle:
            self = try .toggle(index: arguments.integer())
        }
    }
}
