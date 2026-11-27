// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public enum IPCWorkspaceCommandName: String, CaseIterable, Hashable, Sendable {
    case switchTo = "switch-workspace"
    case next = "switch-workspace-next"
    case previous = "switch-workspace-previous"
    case backAndForth = "switch-workspace-back-and-forth"
    case switchAnywhere = "switch-workspace-anywhere"
    case switchSlot = "switch-workspace-slot"
    case moveTo = "move-to-workspace"
    case moveUp = "move-to-workspace-up"
    case moveDown = "move-to-workspace-down"
    case moveToOnMonitor = "move-to-workspace-on-monitor"
    case moveToSlot = "move-to-workspace-slot"
    case moveToMonitor = "move-to-monitor"
}

public enum IPCWorkspaceCommand: Equatable, Sendable {
    case switchTo(workspaceNumber: Int)
    case next
    case previous
    case backAndForth
    case switchAnywhere(workspaceNumber: Int)
    case switchSlot(slotNumber: Int)
    case moveTo(workspaceNumber: Int)
    case moveUp
    case moveDown
    case moveToOnMonitor(workspaceNumber: Int, direction: IPCDirection)
    case moveToSlot(slotNumber: Int)
    case moveToMonitor(direction: IPCDirection)

    public var name: IPCWorkspaceCommandName {
        switch self {
        case .switchTo:
            .switchTo
        case .next:
            .next
        case .previous:
            .previous
        case .backAndForth:
            .backAndForth
        case .switchAnywhere:
            .switchAnywhere
        case .switchSlot:
            .switchSlot
        case .moveTo:
            .moveTo
        case .moveUp:
            .moveUp
        case .moveDown:
            .moveDown
        case .moveToOnMonitor:
            .moveToOnMonitor
        case .moveToSlot:
            .moveToSlot
        case .moveToMonitor:
            .moveToMonitor
        }
    }

    init(name: IPCWorkspaceCommandName, arguments: borrowing IPCCommandArgumentSource)
        throws(IPCCommandRequestConstructionError)
    {
        switch name {
        case .switchTo:
            self = try .switchTo(workspaceNumber: arguments.integer())
        case .next:
            self = try arguments.requireNoArguments(.next)
        case .previous:
            self = try arguments.requireNoArguments(.previous)
        case .backAndForth:
            self = try arguments.requireNoArguments(.backAndForth)
        case .switchAnywhere:
            self = try .switchAnywhere(workspaceNumber: arguments.integer())
        case .switchSlot:
            self = try .switchSlot(slotNumber: arguments.integer())
        case .moveTo:
            self = try .moveTo(workspaceNumber: arguments.integer())
        case .moveUp:
            self = try arguments.requireNoArguments(.moveUp)
        case .moveDown:
            self = try arguments.requireNoArguments(.moveDown)
        case .moveToOnMonitor:
            let values = try arguments.workspaceAndDirection()
            self = .moveToOnMonitor(workspaceNumber: values.workspaceNumber, direction: values.direction)
        case .moveToSlot:
            self = try .moveToSlot(slotNumber: arguments.integer())
        case .moveToMonitor:
            self = try .moveToMonitor(direction: arguments.direction())
        }
    }

    @inlinable
    package static func zeroBasedIndex(from oneBasedValue: Int) -> Int? {
        guard oneBasedValue > 0 else { return nil }
        return oneBasedValue - 1
    }
}
