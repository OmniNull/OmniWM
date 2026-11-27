// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation

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

    init(name: IPCWorkspaceLayoutCommandName, arguments: IPCCommandArgumentSource) throws {
        switch name {
        case .toggle:
            self = try arguments.requireNoArguments(.toggle)
        case .set:
            self = try .set(layout: arguments.layout())
        }
    }

    func encodeArguments(to writer: inout IPCCommandArgumentWriter) throws {
        switch self {
        case let .set(layout):
            try writer.encode(layout: layout)
        case .toggle:
            break
        }
    }
}
