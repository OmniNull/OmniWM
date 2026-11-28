// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public enum IPCFocusCommandName: String, CaseIterable, Hashable, Sendable {
    case spatial = "focus"
    case previous = "focus-previous"
    case downOrLeft = "focus-down-or-left"
    case upOrRight = "focus-up-or-right"
    case windowInColumn = "focus-window-in-column"
    case windowTop = "focus-window-top"
    case windowBottom = "focus-window-bottom"
    case windowDownOrTop = "focus-window-down-or-top"
    case windowUpOrBottom = "focus-window-up-or-bottom"
    case windowOrWorkspaceDown = "focus-window-or-workspace-down"
    case windowOrWorkspaceUp = "focus-window-or-workspace-up"
    case column = "focus-column"
    case columnFirst = "focus-column-first"
    case columnLast = "focus-column-last"
    case centerColumn = "center-column"
    case centerVisibleColumns = "center-visible-columns"
}

public enum IPCFocusCommand: Equatable, Sendable {
    case spatial(direction: IPCDirection)
    case previous
    case downOrLeft
    case upOrRight
    case windowInColumn(windowIndex: Int)
    case windowTop
    case windowBottom
    case windowDownOrTop
    case windowUpOrBottom
    case windowOrWorkspaceDown
    case windowOrWorkspaceUp
    case column(columnIndex: Int)
    case columnFirst
    case columnLast
    case centerColumn
    case centerVisibleColumns

    public var name: IPCFocusCommandName {
        switch self {
        case .spatial:
            .spatial
        case .previous:
            .previous
        case .downOrLeft:
            .downOrLeft
        case .upOrRight:
            .upOrRight
        case .windowInColumn:
            .windowInColumn
        case .windowTop:
            .windowTop
        case .windowBottom:
            .windowBottom
        case .windowDownOrTop:
            .windowDownOrTop
        case .windowUpOrBottom:
            .windowUpOrBottom
        case .windowOrWorkspaceDown:
            .windowOrWorkspaceDown
        case .windowOrWorkspaceUp:
            .windowOrWorkspaceUp
        case .column:
            .column
        case .columnFirst:
            .columnFirst
        case .columnLast:
            .columnLast
        case .centerColumn:
            .centerColumn
        case .centerVisibleColumns:
            .centerVisibleColumns
        }
    }

    init(name: IPCFocusCommandName, arguments: borrowing IPCCommandArgumentSource)
        throws(IPCCommandRequestConstructionError)
    {
        switch name {
        case .spatial:
            self = try .spatial(direction: arguments.direction())
        case .previous:
            self = try arguments.requireNoArguments(.previous)
        case .downOrLeft:
            self = try arguments.requireNoArguments(.downOrLeft)
        case .upOrRight:
            self = try arguments.requireNoArguments(.upOrRight)
        case .windowInColumn:
            self = try .windowInColumn(windowIndex: arguments.integer())
        case .windowTop:
            self = try arguments.requireNoArguments(.windowTop)
        case .windowBottom:
            self = try arguments.requireNoArguments(.windowBottom)
        case .windowDownOrTop:
            self = try arguments.requireNoArguments(.windowDownOrTop)
        case .windowUpOrBottom:
            self = try arguments.requireNoArguments(.windowUpOrBottom)
        case .windowOrWorkspaceDown:
            self = try arguments.requireNoArguments(.windowOrWorkspaceDown)
        case .windowOrWorkspaceUp:
            self = try arguments.requireNoArguments(.windowOrWorkspaceUp)
        case .column:
            self = try .column(columnIndex: arguments.integer())
        case .columnFirst:
            self = try arguments.requireNoArguments(.columnFirst)
        case .columnLast:
            self = try arguments.requireNoArguments(.columnLast)
        case .centerColumn:
            self = try arguments.requireNoArguments(.centerColumn)
        case .centerVisibleColumns:
            self = try arguments.requireNoArguments(.centerVisibleColumns)
        }
    }
}
