// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public enum IPCWindowMovementCommandName: String, CaseIterable, Hashable, Sendable {
    case spatial = "move"
    case down = "move-window-down"
    case up = "move-window-up"
    case downOrToWorkspaceDown = "move-window-down-or-to-workspace-down"
    case upOrToWorkspaceUp = "move-window-up-or-to-workspace-up"
    case consumeOrExpelLeft = "consume-or-expel-window-left"
    case consumeOrExpelRight = "consume-or-expel-window-right"
    case consumeIntoColumn = "consume-window-into-column"
    case expelFromColumn = "expel-window-from-column"
}

public enum IPCWindowMovementCommand: Equatable, Sendable {
    case spatial(direction: IPCDirection)
    case down
    case up
    case downOrToWorkspaceDown
    case upOrToWorkspaceUp
    case consumeOrExpelLeft
    case consumeOrExpelRight
    case consumeIntoColumn
    case expelFromColumn

    public var name: IPCWindowMovementCommandName {
        switch self {
        case .spatial:
            .spatial
        case .down:
            .down
        case .up:
            .up
        case .downOrToWorkspaceDown:
            .downOrToWorkspaceDown
        case .upOrToWorkspaceUp:
            .upOrToWorkspaceUp
        case .consumeOrExpelLeft:
            .consumeOrExpelLeft
        case .consumeOrExpelRight:
            .consumeOrExpelRight
        case .consumeIntoColumn:
            .consumeIntoColumn
        case .expelFromColumn:
            .expelFromColumn
        }
    }

    init(name: IPCWindowMovementCommandName, arguments: borrowing IPCCommandArgumentSource)
        throws(IPCCommandRequestConstructionError)
    {
        switch name {
        case .spatial:
            self = try .spatial(direction: arguments.direction())
        case .down:
            self = try arguments.requireNoArguments(.down)
        case .up:
            self = try arguments.requireNoArguments(.up)
        case .downOrToWorkspaceDown:
            self = try arguments.requireNoArguments(.downOrToWorkspaceDown)
        case .upOrToWorkspaceUp:
            self = try arguments.requireNoArguments(.upOrToWorkspaceUp)
        case .consumeOrExpelLeft:
            self = try arguments.requireNoArguments(.consumeOrExpelLeft)
        case .consumeOrExpelRight:
            self = try arguments.requireNoArguments(.consumeOrExpelRight)
        case .consumeIntoColumn:
            self = try arguments.requireNoArguments(.consumeIntoColumn)
        case .expelFromColumn:
            self = try arguments.requireNoArguments(.expelFromColumn)
        }
    }
}
