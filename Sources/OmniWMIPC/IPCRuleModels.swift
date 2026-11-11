// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

public struct IPCRuleDefinition: Codable, Equatable, Sendable {
    public let bundleId: String
    public let appNameSubstring: String?
    public let titleSubstring: String?
    public let titleRegex: String?
    public let axRole: String?
    public let axSubrole: String?
    public let layout: IPCRuleLayout
    public let assignToWorkspace: String?
    public let initialContainerPrimarySpan: Double?
    public let minWidth: Double?
    public let minHeight: Double?
    public let scratchpad: Int?

    public init(
        bundleId: String,
        appNameSubstring: String? = nil,
        titleSubstring: String? = nil,
        titleRegex: String? = nil,
        axRole: String? = nil,
        axSubrole: String? = nil,
        layout: IPCRuleLayout = .auto,
        assignToWorkspace: String? = nil,
        initialContainerPrimarySpan: Double? = nil,
        minWidth: Double? = nil,
        minHeight: Double? = nil,
        scratchpad: Int? = nil
    ) {
        self.bundleId = bundleId
        self.appNameSubstring = appNameSubstring
        self.titleSubstring = titleSubstring
        self.titleRegex = titleRegex
        self.axRole = axRole
        self.axSubrole = axSubrole
        self.layout = layout
        self.assignToWorkspace = assignToWorkspace
        self.initialContainerPrimarySpan = initialContainerPrimarySpan
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.scratchpad = scratchpad
    }
}

public enum IPCRuleApplyTarget: Equatable, Sendable {
    case focused
    case window(windowId: String)
    case pid(Int32)
}

extension IPCRuleApplyTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case windowId
        case pid
    }

    private enum Kind: String, Codable {
        case focused
        case window
        case pid
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .focused:
            self = .focused
        case .window:
            self = .window(windowId: try container.decode(String.self, forKey: .windowId))
        case .pid:
            self = .pid(try container.decode(Int32.self, forKey: .pid))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .focused:
            try container.encode(Kind.focused, forKey: .kind)
        case let .window(windowId):
            try container.encode(Kind.window, forKey: .kind)
            try container.encode(windowId, forKey: .windowId)
        case let .pid(pid):
            try container.encode(Kind.pid, forKey: .kind)
            try container.encode(pid, forKey: .pid)
        }
    }
}

public enum IPCRuleActionName: String, Codable, CaseIterable, Equatable, Sendable {
    case add
    case replace
    case remove
    case move
    case apply
}

public enum IPCRuleRequest: Equatable, Sendable {
    case add(rule: IPCRuleDefinition)
    case replace(id: String, rule: IPCRuleDefinition)
    case remove(id: String)
    case move(id: String, position: Int)
    case apply(target: IPCRuleApplyTarget)

    public var name: IPCRuleActionName {
        switch self {
        case .add:
            .add
        case .replace:
            .replace
        case .remove:
            .remove
        case .move:
            .move
        case .apply:
            .apply
        }
    }
}

extension IPCRuleRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case arguments
    }

    private struct AddArguments: Codable, Equatable, Sendable {
        let rule: IPCRuleDefinition
    }

    private struct ReplaceArguments: Codable, Equatable, Sendable {
        let id: String
        let rule: IPCRuleDefinition
    }

    private struct RemoveArguments: Codable, Equatable, Sendable {
        let id: String
    }

    private struct MoveArguments: Codable, Equatable, Sendable {
        let id: String
        let position: Int
    }

    private struct ApplyArguments: Codable, Equatable, Sendable {
        let target: IPCRuleApplyTarget
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(IPCRuleActionName.self, forKey: .name)

        switch name {
        case .add:
            let arguments = try container.decode(AddArguments.self, forKey: .arguments)
            self = .add(rule: arguments.rule)
        case .replace:
            let arguments = try container.decode(ReplaceArguments.self, forKey: .arguments)
            self = .replace(id: arguments.id, rule: arguments.rule)
        case .remove:
            let arguments = try container.decode(RemoveArguments.self, forKey: .arguments)
            self = .remove(id: arguments.id)
        case .move:
            let arguments = try container.decode(MoveArguments.self, forKey: .arguments)
            self = .move(id: arguments.id, position: arguments.position)
        case .apply:
            let arguments = try container.decode(ApplyArguments.self, forKey: .arguments)
            self = .apply(target: arguments.target)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)

        switch self {
        case let .add(rule):
            try container.encode(AddArguments(rule: rule), forKey: .arguments)
        case let .replace(id, rule):
            try container.encode(ReplaceArguments(id: id, rule: rule), forKey: .arguments)
        case let .remove(id):
            try container.encode(RemoveArguments(id: id), forKey: .arguments)
        case let .move(id, position):
            try container.encode(MoveArguments(id: id, position: position), forKey: .arguments)
        case let .apply(target):
            try container.encode(ApplyArguments(target: target), forKey: .arguments)
        }
    }
}

public struct IPCRuleSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let position: Int
    public let bundleId: String
    public let appNameSubstring: String?
    public let titleSubstring: String?
    public let titleRegex: String?
    public let axRole: String?
    public let axSubrole: String?
    public let layout: IPCRuleLayout
    public let assignToWorkspace: String?
    public let initialContainerPrimarySpan: Double?
    public let minWidth: Double?
    public let minHeight: Double?
    public let scratchpad: Int?
    public let specificity: Int
    public let isValid: Bool
    public let invalidRegexMessage: String?
    public let validationMessages: [String]

    private enum CodingKeys: String, CodingKey {
        case id, position, bundleId, appNameSubstring, titleSubstring, titleRegex, axRole, axSubrole
        case layout, assignToWorkspace, initialContainerPrimarySpan, minWidth, minHeight, scratchpad, specificity,
             isValid
        case invalidRegexMessage, validationMessages
    }

    public init(
        id: String,
        position: Int,
        bundleId: String,
        appNameSubstring: String? = nil,
        titleSubstring: String? = nil,
        titleRegex: String? = nil,
        axRole: String? = nil,
        axSubrole: String? = nil,
        layout: IPCRuleLayout,
        assignToWorkspace: String? = nil,
        initialContainerPrimarySpan: Double? = nil,
        minWidth: Double? = nil,
        minHeight: Double? = nil,
        scratchpad: Int? = nil,
        specificity: Int,
        isValid: Bool,
        invalidRegexMessage: String? = nil,
        validationMessages: [String] = []
    ) {
        self.id = id
        self.position = position
        self.bundleId = bundleId
        self.appNameSubstring = appNameSubstring
        self.titleSubstring = titleSubstring
        self.titleRegex = titleRegex
        self.axRole = axRole
        self.axSubrole = axSubrole
        self.layout = layout
        self.assignToWorkspace = assignToWorkspace
        self.initialContainerPrimarySpan = initialContainerPrimarySpan
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.scratchpad = scratchpad
        self.specificity = specificity
        self.isValid = isValid
        self.invalidRegexMessage = invalidRegexMessage
        self.validationMessages = validationMessages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        position = try container.decode(Int.self, forKey: .position)
        bundleId = try container.decode(String.self, forKey: .bundleId)
        appNameSubstring = try container.decodeIfPresent(String.self, forKey: .appNameSubstring)
        titleSubstring = try container.decodeIfPresent(String.self, forKey: .titleSubstring)
        titleRegex = try container.decodeIfPresent(String.self, forKey: .titleRegex)
        axRole = try container.decodeIfPresent(String.self, forKey: .axRole)
        axSubrole = try container.decodeIfPresent(String.self, forKey: .axSubrole)
        layout = try container.decode(IPCRuleLayout.self, forKey: .layout)
        assignToWorkspace = try container.decodeIfPresent(String.self, forKey: .assignToWorkspace)
        initialContainerPrimarySpan = try container.decodeIfPresent(Double.self, forKey: .initialContainerPrimarySpan)
        minWidth = try container.decodeIfPresent(Double.self, forKey: .minWidth)
        minHeight = try container.decodeIfPresent(Double.self, forKey: .minHeight)
        scratchpad = try container.decodeIfPresent(Int.self, forKey: .scratchpad)
        specificity = try container.decode(Int.self, forKey: .specificity)
        isValid = try container.decode(Bool.self, forKey: .isValid)
        invalidRegexMessage = try container.decodeIfPresent(String.self, forKey: .invalidRegexMessage)
        validationMessages = try container.decodeIfPresent([String].self, forKey: .validationMessages) ?? []
    }
}

public struct IPCRulesQueryResult: Codable, Equatable, Sendable {
    public let rules: [IPCRuleSnapshot]

    public init(rules: [IPCRuleSnapshot]) {
        self.rules = rules
    }
}
