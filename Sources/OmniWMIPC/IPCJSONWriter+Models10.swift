// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
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

    mutating func value(_ value: borrowing IPCWorkspaceRequest) throws {
        switch value {
        case let .focusName(target):
            begin(123)
            var first = true
            self.key("name", &first)
            try self.value("focus-name")
            self.key("workspaceTarget", &first)
            try self.value(target)
            end(125)
        case let .moveToMonitor(target, direction, force):
            begin(123)
            var first = true
            self.key("direction", &first)
            try self.value(direction)
            self.key("force", &first)
            try self.value(force)
            self.key("name", &first)
            try self.value("move-to-monitor")
            self.key("workspaceTarget", &first)
            try self.value(target)
            end(125)
        case let .rename(target, displayName):
            begin(123)
            var first = true
            self.key("displayName", &first)
            try self.value(displayName)
            self.key("name", &first)
            try self.value("rename")
            self.key("workspaceTarget", &first)
            try self.value(target)
            end(125)
        }
    }

    mutating func value(_ value: borrowing IPCCycleDirection) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCWindowRequest) throws {
        begin(123)
        var first = true
        if let fieldValue = value.change {
            self.key("change", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.columnIndex {
            self.key("columnIndex", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.cycle {
            self.key("cycle", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.direction {
            self.key("direction", &first)
            try self.value(fieldValue)
        }
        self.key("name", &first)
        try self.value(value.name)
        if let fieldValue = value.scratchpadIndex {
            self.key("scratchpadIndex", &first)
            try self.value(fieldValue)
        }
        self.key("windowId", &first)
        try self.value(value.windowId)
        if let fieldValue = value.workspaceTarget {
            self.key("workspaceTarget", &first)
            try self.value(fieldValue)
        }
        end(125)
    }

    mutating func value(_ value: borrowing IPCWindowMarkRequest) throws {
        switch value {
        case let .set(mark):
            begin(123)
            var first = true
            self.key("mark", &first)
            try self.value(mark)
            self.key("name", &first)
            try self.value("set")
            end(125)
        case .list:
            begin(123)
            var first = true
            self.key("name", &first)
            try self.value("list")
            end(125)
        case let .focus(mark):
            begin(123)
            var first = true
            self.key("mark", &first)
            try self.value(mark)
            self.key("name", &first)
            try self.value("focus")
            end(125)
        case let .summon(mark):
            begin(123)
            var first = true
            self.key("mark", &first)
            try self.value(mark)
            self.key("name", &first)
            try self.value("summon")
            end(125)
        case let .remove(mark):
            begin(123)
            var first = true
            self.key("mark", &first)
            try self.value(mark)
            self.key("name", &first)
            try self.value("remove")
            end(125)
        }
    }

    mutating func shellRequestSet(_ key: borrowing String, _ text: borrowing String) throws {
        begin(123)
        var first = true
        self.key("key", &first)
        try self.value(key)
        self.key("name", &first)
        try self.value("set")
        self.key("value", &first)
        try self.value(text)
        end(125)
    }

    mutating func shellRequestUnset(_ key: borrowing String) throws {
        begin(123)
        var first = true
        self.key("key", &first)
        try self.value(key)
        self.key("name", &first)
        try self.value("unset")
        end(125)
    }

    mutating func shellRequestToggle(_ widget: borrowing String) throws {
        begin(123)
        var first = true
        self.key("name", &first)
        try self.value("toggle")
        self.key("widget", &first)
        try self.value(widget)
        end(125)
    }
}
