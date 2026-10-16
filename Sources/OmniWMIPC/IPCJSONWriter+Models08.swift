// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
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

    mutating func arguments(_ value: borrowing IPCColumnCommand, _ first: inout Bool) throws {
        switch value {
        case let .move(direction):
            try argument("direction", direction, &first)
        case let .moveToIndex(columnIndex):
            try argument("columnIndex", columnIndex, &first)
        case let .moveToWorkspace(workspaceNumber):
            try argument("workspaceNumber", workspaceNumber, &first)
        case .moveToFirst,
             .moveToLast,
             .moveToWorkspaceUp,
             .moveToWorkspaceDown,
             .toggleTabbed:
            break
        }
    }

    mutating func value(_ value: borrowing IPCSizeChangeKind) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCSizeChange) throws {
        begin(123)
        var first = true
        self.key("kind", &first)
        try self.value(value.kind)
        self.key("value", &first)
        try self.value(value.value)
        end(125)
    }

    mutating func argument(_ name: StaticString, _ value: borrowing IPCSizeChange, _ first: inout Bool) throws {
        self.key("arguments", &first)
        begin(123)
        var argumentFirst = true
        self.key(name, &argumentFirst)
        try self.value(value)
        end(125)
    }

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
}
