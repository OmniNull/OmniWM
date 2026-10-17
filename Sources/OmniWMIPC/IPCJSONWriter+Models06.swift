// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
    mutating func value(_ value: borrowing IPCWindowMarkActionDescriptor) throws {
        begin(123)
        var first = true
        self.key("arguments", &first)
        try self.value(value.arguments)
        self.key("name", &first)
        try self.value(value.name)
        self.key("path", &first)
        try self.value(value.path)
        self.key("summary", &first)
        try self.value(value.summary)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCWindowMarkActionDescriptor]) throws {
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

    mutating func value(_ value: borrowing IPCWorkspaceActionName) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCWorkspaceActionDescriptor) throws {
        begin(123)
        var first = true
        self.key("actionWords", &first)
        try self.value(value.actionWords)
        self.key("arguments", &first)
        try self.value(value.arguments)
        self.key("name", &first)
        try self.value(value.name)
        self.key("optionalFlags", &first)
        try self.value(value.optionalFlags)
        self.key("path", &first)
        try self.value(value.path)
        self.key("summary", &first)
        try self.value(value.summary)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCWorkspaceActionDescriptor]) throws {
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

    mutating func value(_ value: borrowing IPCCommandsQueryResult) throws {
        begin(123)
        var first = true
        self.key("commands", &first)
        try self.value(value.commands)
        self.key("shellActions", &first)
        try self.value(value.shellActions)
        self.key("windowActions", &first)
        try self.value(value.windowActions)
        self.key("windowMarkActions", &first)
        try self.value(value.windowMarkActions)
        self.key("workspaceActions", &first)
        try self.value(value.workspaceActions)
        end(125)
    }

    mutating func value(_ value: borrowing IPCSubscriptionChannel) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCSubscriptionDescriptor) throws {
        begin(123)
        var first = true
        self.key("channel", &first)
        try self.value(value.channel)
        self.key("resultKind", &first)
        try self.value(value.resultKind)
        self.key("summary", &first)
        try self.value(value.summary)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCSubscriptionDescriptor]) throws {
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

    mutating func value(_ value: borrowing IPCSubscriptionsQueryResult) throws {
        begin(123)
        var first = true
        self.key("subscriptions", &first)
        try self.value(value.subscriptions)
        end(125)
    }

    mutating func value(_ value: borrowing IPCCaptureActionName) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCCaptureActionDescriptor) throws {
        begin(123)
        var first = true
        self.key("arguments", &first)
        try self.value(value.arguments)
        self.key("name", &first)
        try self.value(value.name)
        self.key("path", &first)
        try self.value(value.path)
        self.key("summary", &first)
        try self.value(value.summary)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCCaptureActionDescriptor]) throws {
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

    mutating func value(_ value: borrowing IPCCapabilitiesQueryResult) throws {
        begin(123)
        var first = true
        if let fieldValue = value.appVersion {
            self.key("appVersion", &first)
            try self.value(fieldValue)
        }
        self.key("authorizationRequired", &first)
        try self.value(value.authorizationRequired)
        self.key("captureActions", &first)
        try self.value(value.captureActions)
        self.key("commands", &first)
        try self.value(value.commands)
        self.key("protocolVersion", &first)
        try self.value(value.protocolVersion)
        self.key("queries", &first)
        try self.value(value.queries)
        self.key("ruleActions", &first)
        try self.value(value.ruleActions)
        self.key("shellActions", &first)
        try self.value(value.shellActions)
        self.key("subscriptions", &first)
        try self.value(value.subscriptions)
        self.key("windowActions", &first)
        try self.value(value.windowActions)
        self.key("windowIdScope", &first)
        try self.value(value.windowIdScope)
        self.key("windowMarkActions", &first)
        try self.value(value.windowMarkActions)
        self.key("workspaceActions", &first)
        try self.value(value.workspaceActions)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCSubscriptionChannel]) throws {
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

    mutating func value(_ value: borrowing IPCSubscribeResult) throws {
        begin(123)
        var first = true
        self.key("channels", &first)
        try self.value(value.channels)
        end(125)
    }

    mutating func value(_ value: borrowing IPCWindowMarkEntry) throws {
        begin(123)
        var first = true
        self.key("app", &first)
        try self.value(value.app)
        self.key("id", &first)
        try self.value(value.id)
        self.key("name", &first)
        try self.value(value.name)
        if let fieldValue = value.title {
            self.key("title", &first)
            try self.value(fieldValue)
        }
        self.key("workspace", &first)
        try self.value(value.workspace)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCWindowMarkEntry]) throws {
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

    mutating func value(_ value: borrowing IPCWindowMarksResult) throws {
        begin(123)
        var first = true
        self.key("marks", &first)
        try self.value(value.marks)
        end(125)
    }
}
