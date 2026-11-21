// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
    mutating func arguments(_ value: borrowing IPCColumnCommand, _ first: inout Bool) throws {
        switch value {
        case let .move(direction):
            try argument("direction", direction, &first)
        case let .moveToIndex(columnIndex):
            try argument("columnIndex", columnIndex, &first)
        case let .moveToWorkspace(workspaceNumber):
            try argument("workspaceNumber", workspaceNumber, &first)
        case .moveToFirst,
             .moveToLast,
             .moveToWorkspaceUp,
             .moveToWorkspaceDown,
             .toggleTabbed:
            break
        }
    }

    mutating func value(_ value: borrowing IPCSizeChangeKind) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCSizeChange) throws {
        begin(123)
        var first = true
        self.key("kind", &first)
        try self.value(value.kind)
        self.key("value", &first)
        try self.value(value.value)
        end(125)
    }

    mutating func argument(_ name: StaticString, _ value: borrowing IPCSizeChange, _ first: inout Bool) throws {
        self.key("arguments", &first)
        begin(123)
        var argumentFirst = true
        self.key(name, &argumentFirst)
        try self.value(value)
        end(125)
    }

    mutating func arguments(_ value: borrowing IPCSizingCommand, _ first: inout Bool) throws {
        switch value {
        case let .setContainerPrimarySpan(change):
            try argument("change", change, &first)
        case let .setWindowPrimarySpan(change):
            try argument("change", change, &first)
        case let .setWindowSecondarySpan(change):
            try argument("change", change, &first)
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

    mutating func value(_ value: borrowing IPCResizeAxis) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCResizeOperation) throws {
        try self.value(value.rawValue)
    }

    mutating func argument(_ name: StaticString, _ value: borrowing IPCResizeOperation, _ first: inout Bool) throws {
        self.key("arguments", &first)
        begin(123)
        var argumentFirst = true
        self.key(name, &argumentFirst)
        try self.value(value)
        end(125)
    }

    mutating func arguments(_ value: borrowing IPCDwindleCommand, _ first: inout Bool) throws {
        switch value {
        case let .resize(axis, operation):
            self.key("arguments", &first)
            begin(123)
            var argumentFirst = true
            self.key("axis", &argumentFirst)
            try self.value(axis)
            self.key("operation", &argumentFirst)
            try self.value(operation)
            end(125)
        case let .resizeFocused(operation):
            try argument("operation", operation, &first)
        case let .preselect(direction):
            try argument("direction", direction, &first)
        case .balanceSizes,
             .moveToRoot,
             .toggleSplit,
             .swapSplit,
             .preselectClear:
            break
        }
    }

    mutating func argument(_ name: StaticString, _ value: borrowing IPCWorkspaceLayout, _ first: inout Bool) throws {
        self.key("arguments", &first)
        begin(123)
        var argumentFirst = true
        self.key(name, &argumentFirst)
        try self.value(value)
        end(125)
    }

    mutating func arguments(_ value: borrowing IPCWorkspaceLayoutCommand, _ first: inout Bool) throws {
        switch value {
        case let .set(layout):
            try argument("layout", layout, &first)
        case .toggle:
            break
        }
    }

    mutating func arguments(_ value: borrowing IPCScratchpadCommand, _ first: inout Bool) throws {
        switch value {
        case let .assign(index):
            try argument("scratchpadIndex", index, &first)
        case let .toggle(index):
            try argument("scratchpadIndex", index, &first)
        }
    }

    mutating func value(_ value: borrowing IPCCommandPaletteMode) throws {
        try self.value(value.rawValue)
    }

    mutating func argument(_ name: StaticString, _ value: borrowing String, _ first: inout Bool) throws {
        self.key("arguments", &first)
        begin(123)
        var argumentFirst = true
        self.key(name, &argumentFirst)
        try self.value(value)
        end(125)
    }

    mutating func value(_ value: borrowing IPCWindowSwitcherDirection) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCWindowSwitcherScope) throws {
        try self.value(value.rawValue)
    }

    mutating func windowSwitcherArguments(
        _ direction: IPCWindowSwitcherDirection,
        _ scope: IPCWindowSwitcherScope?,
        _ first: inout Bool
    ) throws {
        self.key("arguments", &first)
        begin(123)
        var argumentFirst = true
        self.key("direction", &argumentFirst)
        try self.value(direction)
        switch scope {
        case let fieldValue?:
            self.key("scope", &argumentFirst)
            try self.value(fieldValue)
        case nil:
            break
        }
        end(125)
    }

    mutating func value(_ value: borrowing IPCCommandRequest) throws {
        begin(123)
        var first = true
        switch value {
        case let .shellAppOpen(appID),
             let .shellAppNewWindow(appID):
            try argument("appId", appID, &first)
        case let .focus(command):
            try arguments(command, &first)
        case let .windowMovement(command):
            try arguments(command, &first)
        case let .workspace(command):
            try arguments(command, &first)
        case let .column(command):
            try arguments(command, &first)
        case let .sizing(command):
            try arguments(command, &first)
        case let .dwindle(command):
            try arguments(command, &first)
        case let .workspaceLayout(command):
            try arguments(command, &first)
        case let .scratchpad(command):
            try arguments(command, &first)
        case let .swapWorkspaceWithMonitor(argument):
            try self.argument("direction", argument, &first)
        case let .openCommandPaletteMode(argument):
            try self.argument("mode", argument.rawValue, &first)
        case let .windowSwitcher(direction, scope):
            try windowSwitcherArguments(direction, scope, &first)
        case .monitorFocus,
             .openCommandPalette,
             .raiseAllFloatingWindows,
             .toggleFloatingFocus,
             .rescueOffscreenWindows,
             .fullscreen,
             .presentation,
             .media,
             .keyboardMode,
             .windowState,
             .openMenuAnywhere:
            break
        }
        self.key("name", &first)
        try self.value(value.name)
        end(125)
    }

    mutating func value(_ value: borrowing IPCCaptureRequest) throws {
        switch value {
        case let .start(profile):
            begin(123)
            var first = true
            self.key("name", &first)
            try self.value("start")
            self.key("profile", &first)
            try self.value(profile)
            end(125)
        case .stop:
            begin(123)
            var first = true
            self.key("name", &first)
            try self.value("stop")
            end(125)
        case .status:
            begin(123)
            var first = true
            self.key("name", &first)
            try self.value("status")
            end(125)
        }
    }

    mutating func fields0(_ value: borrowing IPCQuerySelectors, _ first: inout Bool) throws {
        if let fieldValue = value.app {
            self.key("app", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.bundleId {
            self.key("bundleId", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.current {
            self.key("current", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.display {
            self.key("display", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.floating {
            self.key("floating", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.focused {
            self.key("focused", &first)
            try self.value(fieldValue)
        }
    }
}
