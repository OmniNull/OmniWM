// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
    mutating func value(_ value: borrowing IPCDisplayRef) throws {
        begin(123)
        var first = true
        self.key("id", &first)
        try self.value(value.id)
        self.key("isMain", &first)
        try self.value(value.isMain)
        self.key("name", &first)
        try self.value(value.name)
        end(125)
    }

    mutating func value(_ value: borrowing IPCAppRef) throws {
        begin(123)
        var first = true
        if let fieldValue = value.bundleId {
            self.key("bundleId", &first)
            try self.value(fieldValue)
        }
        self.key("name", &first)
        try self.value(value.name)
        end(125)
    }

    mutating func value(_ value: borrowing IPCWorkspaceRef) throws {
        begin(123)
        var first = true
        self.key("displayName", &first)
        try self.value(value.displayName)
        self.key("id", &first)
        try self.value(value.id)
        if let fieldValue = value.number {
            self.key("number", &first)
            try self.value(fieldValue)
        }
        self.key("rawName", &first)
        try self.value(value.rawName)
        end(125)
    }

    mutating func value(_ value: borrowing IPCActiveWorkspaceQueryResult) throws {
        begin(123)
        var first = true
        if let fieldValue = value.display {
            self.key("display", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.focusedApp {
            self.key("focusedApp", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.workspace {
            self.key("workspace", &first)
            try self.value(fieldValue)
        }
        end(125)
    }

    mutating func value(_ value: borrowing IPCFocusedMonitorQueryResult) throws {
        begin(123)
        var first = true
        if let fieldValue = value.activeWorkspace {
            self.key("activeWorkspace", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.display {
            self.key("display", &first)
            try self.value(fieldValue)
        }
        end(125)
    }

    mutating func value(_ value: borrowing IPCSize) throws {
        begin(123)
        var first = true
        self.key("height", &first)
        try self.value(value.height)
        self.key("width", &first)
        try self.value(value.width)
        end(125)
    }

    mutating func value(_ value: borrowing IPCManagedAppSummary) throws {
        begin(123)
        var first = true
        self.key("appName", &first)
        try self.value(value.appName)
        self.key("bundleId", &first)
        try self.value(value.bundleId)
        self.key("windowSize", &first)
        try self.value(value.windowSize)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCManagedAppSummary]) throws {
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

    mutating func value(_ value: borrowing IPCAppsQueryResult) throws {
        begin(123)
        var first = true
        self.key("apps", &first)
        try self.value(value.apps)
        end(125)
    }

    mutating func value(_ value: borrowing IPCRect) throws {
        begin(123)
        var first = true
        self.key("height", &first)
        try self.value(value.height)
        self.key("width", &first)
        try self.value(value.width)
        self.key("x", &first)
        try self.value(value.x)
        self.key("y", &first)
        try self.value(value.y)
        end(125)
    }

    mutating func value(_ value: borrowing IPCFocusedWindowSnapshot) throws {
        begin(123)
        var first = true
        if let fieldValue = value.app {
            self.key("app", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.display {
            self.key("display", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.frame {
            self.key("frame", &first)
            try self.value(fieldValue)
        }
        self.key("id", &first)
        try self.value(value.id)
        if let fieldValue = value.isFullscreen {
            self.key("isFullscreen", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.pid {
            self.key("pid", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.title {
            self.key("title", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.workspace {
            self.key("workspace", &first)
            try self.value(fieldValue)
        }
        end(125)
    }

    mutating func value(_ value: borrowing IPCFocusedWindowQueryResult) throws {
        begin(123)
        var first = true
        if let fieldValue = value.window {
            self.key("window", &first)
            try self.value(fieldValue)
        }
        end(125)
    }

    mutating func value(_ value: borrowing IPCHiddenReason) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCLayoutReason) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCManualWindowOverride) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCWindowMode) throws {
        try self.value(value.rawValue)
    }

    mutating func fields0(_ value: borrowing IPCWindowQuerySnapshot, _ first: inout Bool) throws {
        if let fieldValue = value.app {
            self.key("app", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.columnIndex {
            self.key("columnIndex", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.display {
            self.key("display", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.frame {
            self.key("frame", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.hiddenReason {
            self.key("hiddenReason", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.id {
            self.key("id", &first)
            try self.value(fieldValue)
        }
    }

    mutating func fields1(_ value: borrowing IPCWindowQuerySnapshot, _ first: inout Bool) throws {
        if let fieldValue = value.isAppHidden {
            self.key("isAppHidden", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.isFocused {
            self.key("isFocused", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.isFullscreen {
            self.key("isFullscreen", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.isScratchpad {
            self.key("isScratchpad", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.isVisible {
            self.key("isVisible", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.layoutReason {
            self.key("layoutReason", &first)
            try self.value(fieldValue)
        }
    }
}
