// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
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

    mutating func value(_ value: borrowing IPCCommandRequest) throws {
        begin(123)
        var first = true
        switch value {
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
            self.key("arguments", &first)
            begin(123)
            var argumentFirst = true
            self.key("direction", &argumentFirst)
            try self.value(argument)
            end(125)
        case let .openCommandPaletteMode(argument):
            self.key("arguments", &first)
            begin(123)
            var argumentFirst = true
            self.key("mode", &argumentFirst)
            try self.value(argument)
            end(125)
        case .monitorFocus,
             .openCommandPalette,
             .raiseAllFloatingWindows,
             .toggleFloatingFocus,
             .rescueOffscreenWindows,
             .fullscreen,
             .presentation,
             .media,
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

    mutating func value(_ value: borrowing IPCQueryRequest) throws {
        begin(123)
        var first = true
        self.key("fields", &first)
        try self.value(value.fields)
        self.key("name", &first)
        try self.value(value.name)
        self.key("selectors", &first)
        try self.value(value.selectors)
        end(125)
    }

    mutating func fields0(_ value: borrowing IPCRuleDefinition, _ first: inout Bool) throws {
        if let fieldValue = value.appNameSubstring {
            self.key("appNameSubstring", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.assignToWorkspace {
            self.key("assignToWorkspace", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.axRole {
            self.key("axRole", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.axSubrole {
            self.key("axSubrole", &first)
            try self.value(fieldValue)
        }
        self.key("bundleId", &first)
        try self.value(value.bundleId)
        if let fieldValue = value.initialContainerPrimarySpan {
            self.key("initialContainerPrimarySpan", &first)
            try self.value(fieldValue)
        }
    }

    mutating func fields1(_ value: borrowing IPCRuleDefinition, _ first: inout Bool) throws {
        self.key("layout", &first)
        try self.value(value.layout)
        if let fieldValue = value.minHeight {
            self.key("minHeight", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.minWidth {
            self.key("minWidth", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.titleRegex {
            self.key("titleRegex", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.titleSubstring {
            self.key("titleSubstring", &first)
            try self.value(fieldValue)
        }
    }

    mutating func value(_ value: borrowing IPCRuleDefinition) throws {
        begin(123)
        var first = true
        try fields0(value, &first)
        try fields1(value, &first)
        end(125)
    }

    mutating func value(_ value: borrowing IPCRuleApplyTarget) throws {
        switch value {
        case .focused:
            begin(123)
            var first = true
            self.key("kind", &first)
            try self.value("focused")
            end(125)
        case let .window(id):
            begin(123)
            var first = true
            self.key("kind", &first)
            try self.value("window")
            self.key("windowId", &first)
            try self.value(id)
            end(125)
        case let .pid(pid):
            begin(123)
            var first = true
            self.key("kind", &first)
            try self.value("pid")
            self.key("pid", &first)
            try self.value(pid)
            end(125)
        }
    }
}
