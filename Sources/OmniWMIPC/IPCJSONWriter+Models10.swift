// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
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

    mutating func ruleRequestReplace(_ id: borrowing String, _ rule: borrowing IPCRuleDefinition) throws {
        begin(123)
        var first = true
        self.key("arguments", &first)
        begin(123)
        var firstNested = true
        self.key("id", &firstNested)
        try self.value(id)
        self.key("rule", &firstNested)
        try self.value(rule)
        end(125)
        self.key("name", &first)
        try self.value("replace")
        end(125)
    }

    mutating func ruleRequestRemove(_ id: borrowing String) throws {
        begin(123)
        var first = true
        self.key("arguments", &first)
        begin(123)
        var firstNested = true
        self.key("id", &firstNested)
        try self.value(id)
        end(125)
        self.key("name", &first)
        try self.value("remove")
        end(125)
    }

    mutating func ruleRequestMove(_ id: borrowing String, _ position: borrowing Int) throws {
        begin(123)
        var first = true
        self.key("arguments", &first)
        begin(123)
        var firstNested = true
        self.key("id", &firstNested)
        try self.value(id)
        self.key("position", &firstNested)
        try self.value(position)
        end(125)
        self.key("name", &first)
        try self.value("move")
        end(125)
    }

    mutating func ruleRequestApply(_ target: borrowing IPCRuleApplyTarget) throws {
        begin(123)
        var first = true
        self.key("arguments", &first)
        begin(123)
        var firstNested = true
        self.key("target", &firstNested)
        try self.value(target)
        end(125)
        self.key("name", &first)
        try self.value("apply")
        end(125)
    }

    mutating func value(_ value: borrowing IPCRuleRequest) throws {
        switch value {
        case let .add(rule):
            try ruleRequestAdd(rule)
        case let .replace(id, rule):
            try ruleRequestReplace(id, rule)
        case let .remove(id):
            try ruleRequestRemove(id)
        case let .move(id, position):
            try ruleRequestMove(id, position)
        case let .apply(target):
            try ruleRequestApply(target)
        }
    }

    mutating func value(_ value: borrowing WorkspaceTarget) throws {
        switch value {
        case let .rawID(text):
            begin(123)
            var first = true
            self.key("kind", &first)
            try self.value("raw-id")
            self.key("value", &first)
            try self.value(text)
            end(125)
        case let .displayName(text):
            begin(123)
            var first = true
            self.key("kind", &first)
            try self.value("display-name")
            self.key("value", &first)
            try self.value(text)
            end(125)
        }
    }
}
