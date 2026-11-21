// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
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

    mutating func value(_ value: borrowing IPCWindowGatherReach) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCWindowGatherRequest) throws {
        begin(123)
        var first = true
        self.key("from", &first)
        try self.value(value.from)
        self.key("windowIds", &first)
        try self.value(value.windowIds)
        end(125)
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

    mutating func shellRequestProfile(_ name: borrowing String) throws {
        begin(123)
        var first = true
        self.key("key", &first)
        try self.value(name)
        self.key("name", &first)
        try self.value("profile")
        end(125)
    }

    mutating func shellRequestTheme(_ name: borrowing String, _ scheme: borrowing String?) throws {
        begin(123)
        var first = true
        self.key("key", &first)
        try self.value(name)
        self.key("name", &first)
        try self.value("theme")
        switch scheme {
        case let fieldValue?:
            self.key("value", &first)
            try self.value(fieldValue)
        case nil:
            break
        }
        end(125)
    }

    mutating func shellRequestEject(_ widget: borrowing String) throws {
        begin(123)
        var first = true
        self.key("name", &first)
        try self.value("eject")
        self.key("widget", &first)
        try self.value(widget)
        end(125)
    }

    mutating func shellRequestInitialize(_ widget: borrowing String) throws {
        begin(123)
        var first = true
        self.key("name", &first)
        try self.value("init")
        self.key("widget", &first)
        try self.value(widget)
        end(125)
    }

    mutating func shellRequestTrigger(
        _ widget: borrowing String,
        _ name: borrowing String,
        _ text: borrowing String?
    ) throws {
        begin(123)
        var first = true
        self.key("key", &first)
        try self.value(name)
        self.key("name", &first)
        try self.value("trigger")
        switch text {
        case let fieldValue?:
            self.key("value", &first)
            try self.value(fieldValue)
        case nil:
            break
        }
        self.key("widget", &first)
        try self.value(widget)
        end(125)
    }

    mutating func value(_ value: borrowing IPCShellRequest) throws {
        switch value {
        case let .set(key, text):
            try shellRequestSet(key, text)
        case let .unset(key):
            try shellRequestUnset(key)
        case let .toggle(widget):
            try shellRequestToggle(widget)
        case let .profile(name):
            try shellRequestProfile(name)
        case let .theme(name, scheme):
            try shellRequestTheme(name, scheme)
        case let .eject(widget):
            try shellRequestEject(widget)
        case let .initialize(widget):
            try shellRequestInitialize(widget)
        case let .trigger(widget, name, text):
            try shellRequestTrigger(widget, name, text)
        }
    }
}
