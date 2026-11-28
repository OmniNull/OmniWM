// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

public enum IPCWindowActionName: String, Codable, CaseIterable, Equatable, Sendable {
    case focus
    case navigate
    case summonRight = "summon-right"
    case moveToWorkspace = "move-to-workspace"
    case close
    case moveColumnToFirst = "move-column-to-first"
    case moveColumnToLast = "move-column-to-last"
    case moveColumnToIndex = "move-column-to-index"
    case moveColumn = "move-column"
    case toggleContainerFullPrimarySpan = "toggle-container-full-primary-span"
    case setContainerPrimarySpan = "set-container-primary-span"
    case setWindowPrimarySpan = "set-window-primary-span"
    case cycleWindowPrimarySpan = "cycle-window-primary-span"
    case setWindowSecondarySpan = "set-window-secondary-span"
    case resetWindowSecondarySpan = "reset-window-secondary-span"
    case cycleWindowSecondarySpan = "cycle-window-secondary-span"
    case toggleColumnTabbed = "toggle-column-tabbed"
    case toggleFloating = "toggle-floating"
    case assignToScratchpad = "assign-to-scratchpad"
}

public enum IPCCycleDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case forward
    case backward
}

package enum IPCWindowActionArgumentKind: String, Sendable {
    case windowID = "opaque-id"
    case workspace
    case number
    case direction
    case sizeChange = "size-change"
    case cycleDirection = "cycle-direction"
}

package struct IPCWindowActionForm: Sendable {
    package let name: IPCWindowActionName
    package let arguments: [IPCWindowActionArgumentKind]

    private init(_ name: IPCWindowActionName, _ arguments: IPCWindowActionArgumentKind...) {
        self.name = name
        self.arguments = [.windowID] + arguments
    }

    package static let all: [Self] = [
        .init(.focus),
        .init(.navigate),
        .init(.summonRight),
        .init(.close),
        .init(.moveToWorkspace, .workspace),
        .init(.moveColumnToFirst),
        .init(.moveColumnToLast),
        .init(.moveColumnToIndex, .number),
        .init(.moveColumn, .direction),
        .init(.toggleContainerFullPrimarySpan),
        .init(.setContainerPrimarySpan, .sizeChange),
        .init(.setWindowPrimarySpan, .sizeChange),
        .init(.cycleWindowPrimarySpan, .cycleDirection),
        .init(.setWindowSecondarySpan, .sizeChange),
        .init(.resetWindowSecondarySpan),
        .init(.cycleWindowSecondarySpan, .cycleDirection),
        .init(.toggleColumnTabbed),
        .init(.toggleFloating),
        .init(.assignToScratchpad, .number)
    ]
}
