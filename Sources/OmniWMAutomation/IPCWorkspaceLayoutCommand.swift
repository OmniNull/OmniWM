// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public enum IPCWorkspaceLayoutCommandName: String, CaseIterable, Hashable, Sendable {
    case toggle = "toggle-workspace-layout"
    case set = "set-workspace-layout"
}

public enum IPCWorkspaceLayoutCommand: Equatable, Sendable {
    case toggle
    case set(layout: IPCWorkspaceLayout)

    public var name: IPCWorkspaceLayoutCommandName {
        switch self {
        case .toggle:
            .toggle
        case .set:
            .set
        }
    }

    init(name: IPCWorkspaceLayoutCommandName, arguments: borrowing IPCCommandArgumentSource)
        throws(IPCCommandRequestConstructionError)
    {
        switch name {
        case .toggle:
            self = try arguments.requireNoArguments(.toggle)
        case .set:
            self = try .set(layout: arguments.layout())
        }
    }
}
