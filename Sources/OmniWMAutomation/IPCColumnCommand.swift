// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public enum IPCColumnCommandName: String, CaseIterable, Hashable, Sendable {
    case move = "move-column"
    case moveToFirst = "move-column-to-first"
    case moveToLast = "move-column-to-last"
    case moveToIndex = "move-column-to-index"
    case moveToWorkspace = "move-column-to-workspace"
    case moveToWorkspaceUp = "move-column-to-workspace-up"
    case moveToWorkspaceDown = "move-column-to-workspace-down"
    case toggleTabbed = "toggle-column-tabbed"
}

public enum IPCColumnCommand: Equatable, Sendable {
    case move(direction: IPCDirection)
    case moveToFirst
    case moveToLast
    case moveToIndex(columnIndex: Int)
    case moveToWorkspace(workspaceNumber: Int)
    case moveToWorkspaceUp
    case moveToWorkspaceDown
    case toggleTabbed

    public var name: IPCColumnCommandName {
        switch self {
        case .move:
            .move
        case .moveToFirst:
            .moveToFirst
        case .moveToLast:
            .moveToLast
        case .moveToIndex:
            .moveToIndex
        case .moveToWorkspace:
            .moveToWorkspace
        case .moveToWorkspaceUp:
            .moveToWorkspaceUp
        case .moveToWorkspaceDown:
            .moveToWorkspaceDown
        case .toggleTabbed:
            .toggleTabbed
        }
    }

    init(name: IPCColumnCommandName, arguments: borrowing IPCCommandArgumentSource)
        throws(IPCCommandRequestConstructionError)
    {
        switch name {
        case .move:
            self = try .move(direction: arguments.direction())
        case .moveToFirst:
            self = try arguments.requireNoArguments(.moveToFirst)
        case .moveToLast:
            self = try arguments.requireNoArguments(.moveToLast)
        case .moveToIndex:
            self = try .moveToIndex(columnIndex: arguments.integer())
        case .moveToWorkspace:
            self = try .moveToWorkspace(workspaceNumber: arguments.integer())
        case .moveToWorkspaceUp:
            self = try arguments.requireNoArguments(.moveToWorkspaceUp)
        case .moveToWorkspaceDown:
            self = try arguments.requireNoArguments(.moveToWorkspaceDown)
        case .toggleTabbed:
            self = try arguments.requireNoArguments(.toggleTabbed)
        }
    }
}
