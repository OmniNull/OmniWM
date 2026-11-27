// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public enum IPCDwindleCommandName: String, CaseIterable, Hashable, Sendable {
    case balanceSizes = "balance-sizes"
    case moveToRoot = "move-to-root"
    case toggleSplit = "toggle-split"
    case swapSplit = "swap-split"
    case resize = "resize"
    case resizeFocused = "resize-focused"
    case resizeDirection = "resize-direction"
    case preselect = "preselect"
    case preselectClear = "preselect-clear"
}

public enum IPCDwindleCommand: Equatable, Sendable {
    case balanceSizes
    case moveToRoot
    case toggleSplit
    case swapSplit
    case resize(axis: IPCResizeAxis, operation: IPCResizeOperation)
    case resizeFocused(operation: IPCResizeOperation)
    case resizeDirection(direction: IPCDirection)
    case preselect(direction: IPCDirection)
    case preselectClear

    public var name: IPCDwindleCommandName {
        switch self {
        case .balanceSizes:
            .balanceSizes
        case .moveToRoot:
            .moveToRoot
        case .toggleSplit:
            .toggleSplit
        case .swapSplit:
            .swapSplit
        case .resize:
            .resize
        case .resizeFocused:
            .resizeFocused
        case .resizeDirection:
            .resizeDirection
        case .preselect:
            .preselect
        case .preselectClear:
            .preselectClear
        }
    }

    init(name: IPCDwindleCommandName, arguments: borrowing IPCCommandArgumentSource)
        throws(IPCCommandRequestConstructionError)
    {
        switch name {
        case .balanceSizes:
            self = try arguments.requireNoArguments(.balanceSizes)
        case .moveToRoot:
            self = try arguments.requireNoArguments(.moveToRoot)
        case .toggleSplit:
            self = try arguments.requireNoArguments(.toggleSplit)
        case .swapSplit:
            self = try arguments.requireNoArguments(.swapSplit)
        case .resize:
            let values = try arguments.resize()
            self = .resize(axis: values.axis, operation: values.operation)
        case .resizeFocused:
            self = try .resizeFocused(operation: arguments.resizeOperation())
        case .resizeDirection:
            self = try .resizeDirection(direction: arguments.direction())
        case .preselect:
            self = try .preselect(direction: arguments.direction())
        case .preselectClear:
            self = try arguments.requireNoArguments(.preselectClear)
        }
    }
}
