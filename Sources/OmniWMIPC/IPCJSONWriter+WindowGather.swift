// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

extension IPCJSONWriter {
    mutating func value(_ value: borrowing IPCWindowGatherRequest) throws {
        begin(123)
        var first = true
        if let fieldValue = value.markNames {
            self.key("markNames", &first)
            try self.value(fieldValue)
        } else {
            self.key("windowIds", &first)
            try self.value(value.windowIds)
        }
        self.key("workspaceTarget", &first)
        try self.value(value.workspaceTarget)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCWorkspaceRef]) throws {
        begin(91)
        var first = true
        let span = value.span
        var index = 0
        while index < span.count {
            item(&first)
            try self.value(span[index])
            index += 1
        }
        end(93)
    }

    mutating func value(_ value: borrowing IPCWindowGatherActionDescriptor) throws {
        begin(123)
        var first = true
        self.key("arguments", &first)
        try self.value(value.arguments)
        self.key("path", &first)
        try self.value(value.path)
        self.key("summary", &first)
        try self.value(value.summary)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCWindowGatherActionDescriptor]) throws {
        begin(91)
        var first = true
        let span = value.span
        var index = 0
        while index < span.count {
            item(&first)
            try self.value(span[index])
            index += 1
        }
        end(93)
    }

    mutating func value(_ value: borrowing IPCWindowGatherWindowResult) throws {
        begin(123)
        var first = true
        if let fieldValue = value.markName {
            self.key("markName", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.reason {
            self.key("reason", &first)
            try self.value(fieldValue.rawValue)
        }
        self.key("status", &first)
        try self.value(value.status.rawValue)
        if let fieldValue = value.windowId {
            self.key("windowId", &first)
            try self.value(fieldValue)
        }
        end(125)
    }

    mutating func value(_ value: borrowing [IPCWindowGatherWindowResult]) throws {
        begin(91)
        var first = true
        let span = value.span
        var index = 0
        while index < span.count {
            item(&first)
            try self.value(span[index])
            index += 1
        }
        end(93)
    }

    mutating func value(_ value: borrowing IPCWindowGatherResult) throws {
        begin(123)
        var first = true
        self.key("modelCommitted", &first)
        try self.value(value.modelCommitted)
        self.key("moved", &first)
        try self.value(value.moved)
        self.key("outcome", &first)
        try self.value(value.outcome.rawValue)
        if let fieldValue = value.reason {
            self.key("reason", &first)
            try self.value(fieldValue.rawValue)
        }
        self.key("relayoutRequested", &first)
        try self.value(value.relayoutRequested)
        self.key("relayoutWorkspaces", &first)
        try self.value(value.relayoutWorkspaces)
        self.key("windows", &first)
        try self.value(value.windows)
        if let fieldValue = value.workspace {
            self.key("workspace", &first)
            try self.value(fieldValue)
        }
        end(125)
    }
}
