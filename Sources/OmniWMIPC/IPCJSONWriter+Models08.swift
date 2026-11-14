// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
    mutating func value(_ value: borrowing [IPCShellWidget]) throws {
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

    mutating func value(_ value: borrowing IPCShellWidgetsQueryResult) throws {
        begin(123)
        var first = true
        self.key("problems", &first)
        try self.value(value.problems)
        self.key("profile", &first)
        try self.value(value.profile)
        self.key("widgets", &first)
        try self.value(value.widgets)
        end(125)
    }

    mutating func value(_ value: borrowing IPCResult.Payload) throws {
        switch value {
        case let .pong(payload):
            try self.value(payload)
        case let .version(payload):
            try self.value(payload)
        case let .capture(payload):
            try self.value(payload)
        case let .workspaceBar(payload):
            try self.value(payload)
        case let .activeWorkspace(payload):
            try self.value(payload)
        case let .focusedMonitor(payload):
            try self.value(payload)
        case let .apps(payload):
            try self.value(payload)
        case let .focusedWindow(payload):
            try self.value(payload)
        case let .windows(payload):
            try self.value(payload)
        case let .workspaces(payload):
            try self.value(payload)
        case let .displays(payload):
            try self.value(payload)
        case let .rules(payload):
            try self.value(payload)
        case let .ruleActions(payload):
            try self.value(payload)
        case let .queries(payload):
            try self.value(payload)
        case let .commands(payload):
            try self.value(payload)
        case let .subscriptions(payload):
            try self.value(payload)
        case let .capabilities(payload):
            try self.value(payload)
        case let .subscribed(payload):
            try self.value(payload)
        case let .windowMarks(payload):
            try self.value(payload)
        case let .windowGather(payload):
            try self.value(payload)
        case let .metrics(payload):
            try self.value(payload)
        case let .shellWidgets(payload):
            try self.value(payload)
        }
    }

    mutating func value(_ value: borrowing IPCResult) throws {
        begin(123)
        var first = true
        self.key("kind", &first)
        try self.value(value.kind)
        self.key("payload", &first)
        try self.value(value.payload)
        end(125)
    }

    mutating func value(_ value: borrowing IPCResponseStatus) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCResponse) throws {
        begin(123)
        var first = true
        if let fieldValue = value.code {
            self.key("code", &first)
            try self.value(fieldValue)
        }
        self.key("id", &first)
        try self.value(value.id)
        self.key("kind", &first)
        try self.value(value.kind)
        self.key("ok", &first)
        try self.value(value.ok)
        if let fieldValue = value.result {
            self.key("result", &first)
            try self.value(fieldValue)
        }
        self.key("status", &first)
        try self.value(value.status)
        self.key("version", &first)
        try self.value(value.version)
        end(125)
    }

    mutating func value(_ value: borrowing IPCEventKind) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCEventEnvelope) throws {
        begin(123)
        var first = true
        self.key("channel", &first)
        try self.value(value.channel)
        if let fieldValue = value.code {
            self.key("code", &first)
            try self.value(fieldValue)
        }
        self.key("id", &first)
        try self.value(value.id)
        self.key("kind", &first)
        try self.value(value.kind)
        self.key("ok", &first)
        try self.value(value.ok)
        self.key("result", &first)
        try self.value(value.result)
        self.key("status", &first)
        try self.value(value.status)
        self.key("version", &first)
        try self.value(value.version)
        end(125)
    }

    mutating func value(_ value: borrowing IPCRequestKind) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCNoPayload) throws {
        begin(123)
        end(125)
    }

    mutating func value(_ value: borrowing IPCDirection) throws {
        try self.value(value.rawValue)
    }

    mutating func argument(_ name: StaticString, _ value: borrowing IPCDirection, _ first: inout Bool) throws {
        self.key("arguments", &first)
        begin(123)
        var argumentFirst = true
        self.key(name, &argumentFirst)
        try self.value(value)
        end(125)
    }

    mutating func argument(_ name: StaticString, _ value: borrowing Int, _ first: inout Bool) throws {
        self.key("arguments", &first)
        begin(123)
        var argumentFirst = true
        self.key(name, &argumentFirst)
        try self.value(value)
        end(125)
    }

    mutating func arguments(_ value: borrowing IPCFocusCommand, _ first: inout Bool) throws {
        switch value {
        case let .spatial(direction):
            try argument("direction", direction, &first)
        case let .windowInColumn(windowIndex):
            try argument("windowIndex", windowIndex, &first)
        case let .column(columnIndex):
            try argument("columnIndex", columnIndex, &first)
        case .previous,
             .downOrLeft,
             .upOrRight,
             .windowTop,
             .windowBottom,
             .windowDownOrTop,
             .windowUpOrBottom,
             .windowOrWorkspaceDown,
             .windowOrWorkspaceUp,
             .columnFirst,
             .columnLast,
             .centerColumn,
             .centerVisibleColumns:
            break
        }
    }

    mutating func arguments(_ value: borrowing IPCWindowMovementCommand, _ first: inout Bool) throws {
        switch value {
        case let .spatial(direction):
            try argument("direction", direction, &first)
        case .down,
             .up,
             .downOrToWorkspaceDown,
             .upOrToWorkspaceUp,
             .consumeOrExpelLeft,
             .consumeOrExpelRight,
             .consumeIntoColumn,
             .expelFromColumn:
            break
        }
    }

    mutating func arguments(_ value: borrowing IPCWorkspaceCommand, _ first: inout Bool) throws {
        switch value {
        case let .switchTo(workspaceNumber):
            try argument("workspaceNumber", workspaceNumber, &first)
        case let .switchAnywhere(workspaceNumber):
            try argument("workspaceNumber", workspaceNumber, &first)
        case let .switchSlot(slotNumber):
            try argument("slotNumber", slotNumber, &first)
        case let .moveTo(workspaceNumber):
            try argument("workspaceNumber", workspaceNumber, &first)
        case let .moveToOnMonitor(workspaceNumber, direction):
            self.key("arguments", &first)
            begin(123)
            var argumentFirst = true
            self.key("direction", &argumentFirst)
            try self.value(direction)
            self.key("workspaceNumber", &argumentFirst)
            try self.value(workspaceNumber)
            end(125)
        case let .moveToSlot(slotNumber):
            try argument("slotNumber", slotNumber, &first)
        case let .moveToMonitor(direction):
            try argument("direction", direction, &first)
        case .next,
             .previous,
             .backAndForth,
             .moveUp,
             .moveDown:
            break
        }
    }
}
