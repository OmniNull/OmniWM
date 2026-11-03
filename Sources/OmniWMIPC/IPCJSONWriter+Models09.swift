// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
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

    mutating func fields1(_ value: borrowing IPCQuerySelectors, _ first: inout Bool) throws {
        if let fieldValue = value.main {
            self.key("main", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.scratchpad {
            self.key("scratchpad", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.visible {
            self.key("visible", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.window {
            self.key("window", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.workspace {
            self.key("workspace", &first)
            try self.value(fieldValue)
        }
    }

    mutating func value(_ value: borrowing IPCQuerySelectors) throws {
        begin(123)
        var first = true
        try fields0(value, &first)
        try fields1(value, &first)
        end(125)
    }

    mutating func value(_ value: borrowing IPCQuerySort) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCQueryRequest) throws {
        begin(123)
        var first = true
        self.key("fields", &first)
        try self.value(value.fields)
        self.key("name", &first)
        try self.value(value.name)
        self.key("selectors", &first)
        try self.value(value.selectors)
        if let fieldValue = value.sort {
            self.key("sort", &first)
            try self.value(fieldValue)
        }
        end(125)
    }
}
