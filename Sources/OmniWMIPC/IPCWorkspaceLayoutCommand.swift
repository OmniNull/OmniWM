// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

public enum IPCWorkspaceLayoutCommandName: String, CaseIterable, Hashable, Sendable {
    case toggle = "toggle-workspace-layout"
    case set = "set-workspace-layout"
    case toggleAccordion = "toggle-accordion"
}

public enum IPCWorkspaceLayoutCommand: Equatable, Sendable {
    case toggle
    case set(layout: IPCWorkspaceLayout)
    case toggleAccordion

    public var name: IPCWorkspaceLayoutCommandName {
        switch self {
        case .toggle:
            .toggle
        case .set:
            .set
        case .toggleAccordion:
            .toggleAccordion
        }
    }

    init(name: IPCWorkspaceLayoutCommandName, arguments: IPCCommandArgumentSource) throws {
        switch name {
        case .toggle:
            self = try arguments.requireNoArguments(.toggle)
        case .set:
            self = try .set(layout: arguments.layout())
        case .toggleAccordion:
            self = try arguments.requireNoArguments(.toggleAccordion)
        }
    }

    func encodeArguments(to writer: inout IPCCommandArgumentWriter) throws {
        switch self {
        case let .set(layout):
            try writer.encode(layout: layout)
        case .toggle,
             .toggleAccordion:
            break
        }
    }
}
