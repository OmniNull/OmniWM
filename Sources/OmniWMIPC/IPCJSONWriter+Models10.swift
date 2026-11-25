// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
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
             .openMenuAnywhere,
             .openSettings:
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

    mutating func fields0(_ value: borrowing IPCRuleDefinition, _ first: inout Bool) throws {
        if let fieldValue = value.appNameSubstring {
            self.key("appNameSubstring", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.assignToWorkspace {
            self.key("assignToWorkspace", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.assignToWorkspaceForAllWindows {
            self.key("assignToWorkspaceForAllWindows", &first)
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
    }

    mutating func fields1(_ value: borrowing IPCRuleDefinition, _ first: inout Bool) throws {
        if let fieldValue = value.initialContainerPrimarySpan {
            self.key("initialContainerPrimarySpan", &first)
            try self.value(fieldValue)
        }
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
        if let fieldValue = value.scratchpad {
            self.key("scratchpad", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.titleRegex {
            self.key("titleRegex", &first)
            try self.value(fieldValue)
        }
    }

    mutating func fields2(_ value: borrowing IPCRuleDefinition, _ first: inout Bool) throws {
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
        try fields2(value, &first)
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

    mutating func ruleRequestAdd(_ rule: borrowing IPCRuleDefinition) throws {
        begin(123)
        var first = true
        self.key("arguments", &first)
        begin(123)
        var firstNested = true
        self.key("rule", &firstNested)
        try self.value(rule)
        end(125)
        self.key("name", &first)
        try self.value("add")
        end(125)
    }
}
