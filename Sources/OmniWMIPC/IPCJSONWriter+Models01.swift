// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
    mutating func value(_ value: borrowing IPCErrorCode) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCResponseKind) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCResultKind) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCPingResult) throws {
        begin(123)
        var first = true
        self.key("message", &first)
        try self.value(value.message)
        end(125)
    }

    mutating func value(_ value: borrowing IPCVersionResult) throws {
        begin(123)
        var first = true
        if let fieldValue = value.appVersion {
            self.key("appVersion", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.buildConfiguration {
            self.key("buildConfiguration", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.executableSHA256 {
            self.key("executableSHA256", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.gitHash {
            self.key("gitHash", &first)
            try self.value(fieldValue)
        }
        self.key("protocolVersion", &first)
        try self.value(value.protocolVersion)
        end(125)
    }

    mutating func value(_ value: borrowing IPCCaptureProfile) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCCaptureArtifact) throws {
        begin(123)
        var first = true
        self.key("endedAt", &first)
        try self.value(value.endedAt)
        self.key("path", &first)
        try self.value(value.path)
        self.key("profile", &first)
        try self.value(value.profile)
        self.key("startedAt", &first)
        try self.value(value.startedAt)
        end(125)
    }

    mutating func value(_ value: borrowing IPCCapturePhase) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCCaptureResult) throws {
        begin(123)
        var first = true
        if let fieldValue = value.failureReason {
            self.key("failureReason", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.lastArtifact {
            self.key("lastArtifact", &first)
            try self.value(fieldValue)
        }
        self.key("phase", &first)
        try self.value(value.phase)
        if let fieldValue = value.profile {
            self.key("profile", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.startedAt {
            self.key("startedAt", &first)
            try self.value(fieldValue)
        }
        end(125)
    }

    mutating func value(_ value: borrowing IPCWorkspaceBarWindow) throws {
        begin(123)
        var first = true
        self.key("id", &first)
        try self.value(value.id)
        self.key("isFocused", &first)
        try self.value(value.isFocused)
        self.key("title", &first)
        try self.value(value.title)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCWorkspaceBarWindow]) throws {
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

    mutating func value(_ value: borrowing IPCWorkspaceBarApp) throws {
        begin(123)
        var first = true
        self.key("allWindows", &first)
        try self.value(value.allWindows)
        self.key("appName", &first)
        try self.value(value.appName)
        if let fieldValue = value.bundleId {
            self.key("bundleId", &first)
            try self.value(fieldValue)
        }
        self.key("id", &first)
        try self.value(value.id)
        self.key("isFocused", &first)
        try self.value(value.isFocused)
        self.key("windowCount", &first)
        try self.value(value.windowCount)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCWorkspaceBarApp]) throws {
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

    mutating func value(_ value: borrowing IPCWorkspaceBarScratchpad) throws {
        begin(123)
        var first = true
        self.key("index", &first)
        try self.value(value.index)
        self.key("isVisible", &first)
        try self.value(value.isVisible)
        if let fieldValue = value.label {
            self.key("label", &first)
            try self.value(fieldValue)
        }
        self.key("windows", &first)
        try self.value(value.windows)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCWorkspaceBarScratchpad]) throws {
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

    mutating func value(_ value: borrowing IPCWorkspaceBarWorkspace) throws {
        begin(123)
        var first = true
        self.key("displayName", &first)
        try self.value(value.displayName)
        self.key("id", &first)
        try self.value(value.id)
        self.key("isFocused", &first)
        try self.value(value.isFocused)
        if let fieldValue = value.number {
            self.key("number", &first)
            try self.value(fieldValue)
        }
        self.key("rawName", &first)
        try self.value(value.rawName)
        self.key("windows", &first)
        try self.value(value.windows)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCWorkspaceBarWorkspace]) throws {
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

    mutating func value(_ value: borrowing IPCWorkspaceBarMonitor) throws {
        begin(123)
        var first = true
        self.key("backgroundOpacity", &first)
        try self.value(value.backgroundOpacity)
        self.key("barHeight", &first)
        try self.value(value.barHeight)
        self.key("enabled", &first)
        try self.value(value.enabled)
        self.key("id", &first)
        try self.value(value.id)
        self.key("isVisible", &first)
        try self.value(value.isVisible)
        self.key("name", &first)
        try self.value(value.name)
        self.key("scratchpads", &first)
        try self.value(value.scratchpads)
        self.key("showLabels", &first)
        try self.value(value.showLabels)
        self.key("workspaces", &first)
        try self.value(value.workspaces)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCWorkspaceBarMonitor]) throws {
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

    mutating func value(_ value: borrowing IPCWorkspaceBarQueryResult) throws {
        begin(123)
        var first = true
        if let fieldValue = value.interactionMonitorId {
            self.key("interactionMonitorId", &first)
            try self.value(fieldValue)
        }
        self.key("monitors", &first)
        try self.value(value.monitors)
        end(125)
    }
}
