// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCJSONWriter {
    mutating func fields0(_ value: borrowing IPCDisplayQuerySnapshot, _ first: inout Bool) throws {
        if let fieldValue = value.activeWorkspace {
            self.key("activeWorkspace", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.barFrames {
            self.key("barFrames", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.frame {
            self.key("frame", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.fullscreenUsesOuterGaps {
            self.key("fullscreenUsesOuterGaps", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.hasNotch {
            self.key("hasNotch", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.id {
            self.key("id", &first)
            try self.value(fieldValue)
        }
    }

    mutating func fields1(_ value: borrowing IPCDisplayQuerySnapshot, _ first: inout Bool) throws {
        if let fieldValue = value.innerGap {
            self.key("innerGap", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.isCurrent {
            self.key("isCurrent", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.isMain {
            self.key("isMain", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.menuBarHeight {
            self.key("menuBarHeight", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.name {
            self.key("name", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.notch {
            self.key("notch", &first)
            try self.value(fieldValue)
        }
    }

    mutating func fields2(_ value: borrowing IPCDisplayQuerySnapshot, _ first: inout Bool) throws {
        if let fieldValue = value.orientation {
            self.key("orientation", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.outerGapBottom {
            self.key("outerGapBottom", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.outerGapLeft {
            self.key("outerGapLeft", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.outerGapRight {
            self.key("outerGapRight", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.outerGapTop {
            self.key("outerGapTop", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.reservedInsets {
            self.key("reservedInsets", &first)
            try self.value(fieldValue)
        }
    }

    mutating func fields3(_ value: borrowing IPCDisplayQuerySnapshot, _ first: inout Bool) throws {
        if let fieldValue = value.uuid {
            self.key("uuid", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.visibleFrame {
            self.key("visibleFrame", &first)
            try self.value(fieldValue)
        }
    }

    mutating func value(_ value: borrowing IPCDisplayQuerySnapshot) throws {
        begin(123)
        var first = true
        try fields0(value, &first)
        try fields1(value, &first)
        try fields2(value, &first)
        try fields3(value, &first)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCDisplayQuerySnapshot]) throws {
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

    mutating func value(_ value: borrowing IPCDisplaysQueryResult) throws {
        begin(123)
        var first = true
        self.key("displays", &first)
        try self.value(value.displays)
        end(125)
    }

    mutating func value(_ value: borrowing IPCRuleLayout) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing [String]) throws {
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

    mutating func fields0(_ value: borrowing IPCRuleSnapshot, _ first: inout Bool) throws {
        if let fieldValue = value.appNameSubstring {
            self.key("appNameSubstring", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.assignToWorkspace {
            self.key("assignToWorkspace", &first)
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
        self.key("id", &first)
        try self.value(value.id)
    }

    mutating func fields1(_ value: borrowing IPCRuleSnapshot, _ first: inout Bool) throws {
        if let fieldValue = value.initialContainerPrimarySpan {
            self.key("initialContainerPrimarySpan", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.invalidRegexMessage {
            self.key("invalidRegexMessage", &first)
            try self.value(fieldValue)
        }
        self.key("isValid", &first)
        try self.value(value.isValid)
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
    }

    mutating func fields2(_ value: borrowing IPCRuleSnapshot, _ first: inout Bool) throws {
        self.key("position", &first)
        try self.value(value.position)
        self.key("specificity", &first)
        try self.value(value.specificity)
        if let fieldValue = value.titleRegex {
            self.key("titleRegex", &first)
            try self.value(fieldValue)
        }
        if let fieldValue = value.titleSubstring {
            self.key("titleSubstring", &first)
            try self.value(fieldValue)
        }
        self.key("validationMessages", &first)
        try self.value(value.validationMessages)
    }

    mutating func value(_ value: borrowing IPCRuleSnapshot) throws {
        begin(123)
        var first = true
        try fields0(value, &first)
        try fields1(value, &first)
        try fields2(value, &first)
        end(125)
    }

    mutating func value(_ value: borrowing [IPCRuleSnapshot]) throws {
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

    mutating func value(_ value: borrowing IPCRulesQueryResult) throws {
        begin(123)
        var first = true
        self.key("rules", &first)
        try self.value(value.rules)
        end(125)
    }

    mutating func value(_ value: borrowing IPCRuleActionName) throws {
        try self.value(value.rawValue)
    }

    mutating func value(_ value: borrowing IPCRuleActionOptionDescriptor) throws {
        begin(123)
        var first = true
        if let fieldValue = value.exclusiveGroup {
            self.key("exclusiveGroup", &first)
            try self.value(fieldValue)
        }
        self.key("flag", &first)
        try self.value(value.flag)
        self.key("summary", &first)
        try self.value(value.summary)
        if let fieldValue = value.valuePlaceholder {
            self.key("valuePlaceholder", &first)
            try self.value(fieldValue)
        }
        end(125)
    }
}
