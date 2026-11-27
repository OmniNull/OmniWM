// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation

public enum IPCSizingCommandName: String, CaseIterable, Hashable, Sendable {
    case cycleSizeForward = "cycle-size-forward"
    case cycleSizeBackward = "cycle-size-backward"
    case cycleWindowPrimarySpanForward = "cycle-window-primary-span-forward"
    case cycleWindowPrimarySpanBackward = "cycle-window-primary-span-backward"
    case cycleWindowSecondarySpanForward = "cycle-window-secondary-span-forward"
    case cycleWindowSecondarySpanBackward = "cycle-window-secondary-span-backward"
    case toggleContainerFullPrimarySpan = "toggle-container-full-primary-span"
    case expandContainerToAvailablePrimarySpan = "expand-container-to-available-primary-span"
    case resetWindowSecondarySpan = "reset-window-secondary-span"
    case setContainerPrimarySpan = "set-container-primary-span"
    case setWindowPrimarySpan = "set-window-primary-span"
    case setWindowSecondarySpan = "set-window-secondary-span"
    case setVisibleContainers = "set-visible-containers"
}

public enum IPCSizingCommand: Equatable, Sendable {
    case cycleSizeForward
    case cycleSizeBackward
    case cycleWindowPrimarySpanForward
    case cycleWindowPrimarySpanBackward
    case cycleWindowSecondarySpanForward
    case cycleWindowSecondarySpanBackward
    case toggleContainerFullPrimarySpan
    case expandContainerToAvailablePrimarySpan
    case resetWindowSecondarySpan
    case setContainerPrimarySpan(change: IPCSizeChange)
    case setWindowPrimarySpan(change: IPCSizeChange)
    case setWindowSecondarySpan(change: IPCSizeChange)
    case setVisibleContainers(count: Int)

    public var name: IPCSizingCommandName {
        switch self {
        case .cycleSizeForward:
            .cycleSizeForward
        case .cycleSizeBackward:
            .cycleSizeBackward
        case .cycleWindowPrimarySpanForward:
            .cycleWindowPrimarySpanForward
        case .cycleWindowPrimarySpanBackward:
            .cycleWindowPrimarySpanBackward
        case .cycleWindowSecondarySpanForward:
            .cycleWindowSecondarySpanForward
        case .cycleWindowSecondarySpanBackward:
            .cycleWindowSecondarySpanBackward
        case .toggleContainerFullPrimarySpan:
            .toggleContainerFullPrimarySpan
        case .expandContainerToAvailablePrimarySpan:
            .expandContainerToAvailablePrimarySpan
        case .resetWindowSecondarySpan:
            .resetWindowSecondarySpan
        case .setContainerPrimarySpan:
            .setContainerPrimarySpan
        case .setWindowPrimarySpan:
            .setWindowPrimarySpan
        case .setWindowSecondarySpan:
            .setWindowSecondarySpan
        case .setVisibleContainers:
            .setVisibleContainers
        }
    }

    init(name: IPCSizingCommandName, arguments: IPCCommandArgumentSource) throws {
        switch name {
        case .cycleSizeForward:
            self = try arguments.requireNoArguments(.cycleSizeForward)
        case .cycleSizeBackward:
            self = try arguments.requireNoArguments(.cycleSizeBackward)
        case .cycleWindowPrimarySpanForward:
            self = try arguments.requireNoArguments(.cycleWindowPrimarySpanForward)
        case .cycleWindowPrimarySpanBackward:
            self = try arguments.requireNoArguments(.cycleWindowPrimarySpanBackward)
        case .cycleWindowSecondarySpanForward:
            self = try arguments.requireNoArguments(.cycleWindowSecondarySpanForward)
        case .cycleWindowSecondarySpanBackward:
            self = try arguments.requireNoArguments(.cycleWindowSecondarySpanBackward)
        case .toggleContainerFullPrimarySpan:
            self = try arguments.requireNoArguments(.toggleContainerFullPrimarySpan)
        case .expandContainerToAvailablePrimarySpan:
            self = try arguments.requireNoArguments(.expandContainerToAvailablePrimarySpan)
        case .resetWindowSecondarySpan:
            self = try arguments.requireNoArguments(.resetWindowSecondarySpan)
        case .setContainerPrimarySpan:
            self = try .setContainerPrimarySpan(change: arguments.sizeChange())
        case .setWindowPrimarySpan:
            self = try .setWindowPrimarySpan(change: arguments.sizeChange())
        case .setWindowSecondarySpan:
            self = try .setWindowSecondarySpan(change: arguments.sizeChange())
        case .setVisibleContainers:
            let count = try arguments.integer(.visibleContainerCount)
            guard IPCVisibleContainerCounts.range.contains(count) else {
                throw IPCCommandRequestConstructionError.invalidArgumentType
            }
            self = .setVisibleContainers(count: count)
        }
    }

    func encodeArguments(to writer: inout IPCCommandArgumentWriter) throws {
        switch self {
        case let .setContainerPrimarySpan(change):
            try writer.encode(sizeChange: change)
        case let .setWindowPrimarySpan(change):
            try writer.encode(sizeChange: change)
        case let .setWindowSecondarySpan(change):
            try writer.encode(sizeChange: change)
        case let .setVisibleContainers(count):
            try writer.encode(integer: count, field: .visibleContainerCount)
        case .cycleSizeForward,
             .cycleSizeBackward,
             .cycleWindowPrimarySpanForward,
             .cycleWindowPrimarySpanBackward,
             .cycleWindowSecondarySpanForward,
             .cycleWindowSecondarySpanBackward,
             .toggleContainerFullPrimarySpan,
             .expandContainerToAvailablePrimarySpan,
             .resetWindowSecondarySpan:
            break
        }
    }
}
