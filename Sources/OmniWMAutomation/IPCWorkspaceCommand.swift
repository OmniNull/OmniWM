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

    @inlinable
    package init(
        switchName: IPCWorkspaceCommandName,
        argumentValues: borrowing[IPCCommandArgumentValue]
    ) throws(IPCCommandRequestConstructionError) {
        switch switchName {
        case .switchTo,
             .switchAnywhere,
             .switchSlot:
            guard argumentValues.count == 1, case let .integer(number) = argumentValues[0] else {
                throw .invalidArgumentType
            }
            try self.init(switchName: switchName, number: number)
        case .next,
             .previous,
             .backAndForth:
            guard argumentValues.isEmpty else { throw .invalidArgumentCount }
            switch switchName {
            case .next: self = .next
            case .previous: self = .previous
            default: self = .backAndForth
            }
        default:
            throw .invalidArgumentType
        }
    }

    @inlinable
    package init(
        switchName: IPCWorkspaceCommandName,
        number: Int
    ) throws(IPCCommandRequestConstructionError) {
        switch switchName {
        case .switchTo: self = .switchTo(workspaceNumber: number)
        case .switchAnywhere: self = .switchAnywhere(workspaceNumber: number)
        case .switchSlot: self = .switchSlot(slotNumber: number)
        default: throw .invalidArgumentType
        }
    }

    @inlinable
    package static func zeroBasedIndex(from oneBasedValue: Int) -> Int? {
        guard oneBasedValue > 0 else { return nil }
        return oneBasedValue - 1
    }
}

package struct IPCWorkspaceSwitchForm: Sendable {
    package let name: IPCWorkspaceCommandName
    package let commandWords: [String]
    package let argumentKind: IPCCommandArgumentKind?

    private init(_ name: IPCWorkspaceCommandName, suffix: String? = nil, takesNumber: Bool = false) {
        self.name = name
        let word = IPCWorkspaceCommandName.switchTo.rawValue
        commandWords = suffix.map { [word, $0] } ?? [word]
        argumentKind = takesNumber ? .workspaceNumber : nil
    }

    package static let all: [Self] = [
        Self(.switchTo, takesNumber: true),
        Self(.next, suffix: "next"),
        Self(.previous, suffix: "prev"),
        Self(.backAndForth, suffix: "back-and-forth"),
        Self(.switchAnywhere, suffix: "anywhere", takesNumber: true),
        Self(.switchSlot, suffix: "slot", takesNumber: true)
    ]
}
