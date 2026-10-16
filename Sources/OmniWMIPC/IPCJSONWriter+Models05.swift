// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
    mutating func value(_ value: borrowing [IPCRuleActionOptionDescriptor]) throws {
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

    mutating func value(_ value: borrowing IPCRuleActionDescriptor) throws {
        begin(123)
        var first = true
        self.key("arguments", &first)
        try self.value(value.arguments)
        self.key("name", &first)
        try self.value(value.name)
        self.key("options", &first)
        try self.value(value.options)
        self.key("path", &first)
        try self.value(value.path)
        self.key("summary", &first)
        try self.value(value.summary)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCRuleActionDescriptor]) throws {
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

    mutating func value(_ value: borrowing IPCRuleActionsQueryResult) throws {
        begin(123)
        var first = true
        self.key("ruleActions", &first)
        try self.value(value.ruleActions)
        end(125)
    }

    mutating func value(_ value: borrowing IPCQueryName) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCQuerySelectorName) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCQuerySelectorDescriptor) throws {
        begin(123)
        var first = true
        self.key("name", &first)
        try self.value(value.name)
        self.key("summary", &first)
        try self.value(value.summary)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCQuerySelectorDescriptor]) throws {
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

    mutating func value(_ value: borrowing IPCQueryDescriptor) throws {
        begin(123)
        var first = true
        self.key("fields", &first)
        try self.value(value.fields)
        self.key("name", &first)
        try self.value(value.name)
        self.key("selectors", &first)
        try self.value(value.selectors)
        self.key("summary", &first)
        try self.value(value.summary)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCQueryDescriptor]) throws {
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

    mutating func value(_ value: borrowing IPCQueriesQueryResult) throws {
        begin(123)
        var first = true
        self.key("queries", &first)
        try self.value(value.queries)
        end(125)
    }

    mutating func value(_ value: borrowing IPCCommandArgumentKind) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCCommandArgumentDescriptor) throws {
        begin(123)
        var first = true
        self.key("kind", &first)
        try self.value(value.kind)
        self.key("summary", &first)
        try self.value(value.summary)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCCommandArgumentDescriptor]) throws {
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

    mutating func value(_ value: borrowing IPCAutomationLayoutCompatibility) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCCommandName) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCCommandDescriptor) throws {
        begin(123)
        var first = true
        self.key("arguments", &first)
        try self.value(value.arguments)
        self.key("commandWords", &first)
        try self.value(value.commandWords)
        self.key("layoutCompatibility", &first)
        try self.value(value.layoutCompatibility)
        self.key("name", &first)
        try self.value(value.name)
        self.key("path", &first)
        try self.value(value.path)
        self.key("summary", &first)
        try self.value(value.summary)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCCommandDescriptor]) throws {
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

    mutating func value(_ value: borrowing IPCShellActionName) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCShellActionDescriptor) throws {
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

    mutating func value(_ value: borrowing [IPCShellActionDescriptor]) throws {
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

    mutating func value(_ value: borrowing IPCWindowActionName) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCWindowActionDescriptor) throws {
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

    mutating func value(_ value: borrowing [IPCWindowActionDescriptor]) throws {
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

    mutating func value(_ value: borrowing IPCWindowMarkActionName) throws {
        try self.value(value.rawValue)
    }
}
