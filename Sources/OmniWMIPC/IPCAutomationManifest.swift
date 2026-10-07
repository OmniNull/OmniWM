// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

public enum IPCAutomationLayoutCompatibility: String, Codable, CaseIterable, Equatable, Sendable {
    case shared
    case niri
    case dwindle
}

public enum IPCQuerySelectorName: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case window
    case workspace
    case display
    case focused
    case visible
    case floating
    case scratchpad
    case app
    case bundleId = "bundle-id"
    case current
    case main

    public var flag: String {
        "--\(rawValue)"
    }

    public var expectsValue: Bool {
        switch self {
        case .window,
             .workspace,
             .display,
             .app,
             .bundleId:
            true
        case .focused,
             .visible,
             .floating,
             .scratchpad,
             .current,
             .main:
            false
        }
    }
}

public enum IPCCommandArgumentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case direction
    case workspaceNumber = "workspace-number"
    case columnIndex = "column-index"
    case windowIndex = "window-index"
    case scratchpadIndex = "scratchpad-index"
    case layout
    case paletteMode = "palette-mode"
    case resizeAxis = "resize-axis"
    case resizeOperation = "resize-operation"
    case sizeChange = "size-change"

    public var usagePlaceholder: String {
        switch self {
        case .direction:
            "<left|right|up|down>"
        case .workspaceNumber,
             .columnIndex,
             .windowIndex,
             .scratchpadIndex:
            "<number>"
        case .layout:
            "<default|niri|dwindle>"
        case .paletteMode:
            "<windows|menu|clipboard|commands|applications|files>"
        case .resizeAxis:
            "<horizontal|vertical>"
        case .resizeOperation:
            "<grow|shrink>"
        case .sizeChange:
            "<size-change>"
        }
    }
}

public struct IPCQuerySelectorDescriptor: Codable, Equatable, Sendable {
    public let name: IPCQuerySelectorName
    public let summary: String

    public init(name: IPCQuerySelectorName, summary: String) {
        self.name = name
        self.summary = summary
    }
}

public struct IPCQueryDescriptor: Codable, Equatable, Sendable {
    public let name: IPCQueryName
    public let summary: String
    public let selectors: [IPCQuerySelectorDescriptor]
    public let fields: [String]

    public init(
        name: IPCQueryName,
        summary: String,
        selectors: [IPCQuerySelectorDescriptor] = [],
        fields: [String] = []
    ) {
        self.name = name
        self.summary = summary
        self.selectors = selectors
        self.fields = fields
    }
}

public struct IPCCommandArgumentDescriptor: Codable, Equatable, Sendable {
    public let kind: IPCCommandArgumentKind
    public let summary: String

    static let direction = Self(
        kind: .direction,
        summary: "Direction argument."
    )
    static let workspaceNumber = Self(
        kind: .workspaceNumber,
        summary: "Positive numeric workspace ID."
    )
    static let slotNumber = Self(
        kind: .workspaceNumber,
        summary: "One-based position in the interaction monitor's ordered workspace list."
    )
    static let columnIndex = Self(
        kind: .columnIndex,
        summary: "One-based column index."
    )
    static let windowIndex = Self(
        kind: .windowIndex,
        summary: "One-based window index within the focused column."
    )
    static let scratchpadIndex = Self(
        kind: .scratchpadIndex,
        summary: "Scratchpad slot from 1 to 10."
    )
    static let layout = Self(
        kind: .layout,
        summary: "Workspace layout selection."
    )
    static let paletteMode = Self(
        kind: .paletteMode,
        summary: "Command palette mode."
    )
    static let resizeAxis = Self(
        kind: .resizeAxis,
        summary: "Dwindle split axis."
    )
    static let resizeOperation = Self(
        kind: .resizeOperation,
        summary: "Whether to grow or shrink."
    )
    static let sizeChange = Self(
        kind: .sizeChange,
        summary: "Size change such as 100, 50%, +10, or -10%."
    )

    public init(kind: IPCCommandArgumentKind, summary: String) {
        self.kind = kind
        self.summary = summary
    }
}

public struct IPCCommandDescriptor: Codable, Equatable, Sendable {
    public let commandWords: [String]
    public let path: String
    public let name: IPCCommandName
    public let summary: String
    public let arguments: [IPCCommandArgumentDescriptor]
    public let layoutCompatibility: IPCAutomationLayoutCompatibility

    public init(
        commandWords: [String],
        name: IPCCommandName,
        summary: String,
        arguments: [IPCCommandArgumentDescriptor] = [],
        layoutCompatibility: IPCAutomationLayoutCompatibility = .shared
    ) {
        self.commandWords = commandWords
        self.path = IPCCommandDescriptor.makePath(commandWords: commandWords, arguments: arguments)
        self.name = name
        self.summary = summary
        self.arguments = arguments
        self.layoutCompatibility = layoutCompatibility
    }

    init(
        name: IPCCommandName,
        summary: String,
        arguments: [IPCCommandArgumentDescriptor] = [],
        layoutCompatibility: IPCAutomationLayoutCompatibility = .shared
    ) {
        self.init(
            commandWords: [name.rawValue],
            name: name,
            summary: summary,
            arguments: arguments,
            layoutCompatibility: layoutCompatibility
        )
    }

    private static func makePath(
        commandWords: [String],
        arguments: [IPCCommandArgumentDescriptor]
    ) -> String {
        let parts = ["command"] + commandWords + arguments.map(\.kind.usagePlaceholder)
        return parts.joined(separator: " ")
    }
}

public struct IPCWorkspaceActionDescriptor: Codable, Equatable, Sendable {
    public let actionWords: [String]
    public let path: String
    public let name: IPCWorkspaceActionName
    public let summary: String
    public let arguments: [String]
    public let optionalFlags: [String]

    public init(
        actionWords: [String],
        name: IPCWorkspaceActionName,
        summary: String,
        arguments: [String] = [],
        optionalFlags: [String] = []
    ) {
        self.actionWords = actionWords
        path = Self.makePath(actionWords: actionWords, arguments: arguments, optionalFlags: optionalFlags)
        self.name = name
        self.summary = summary
        self.arguments = arguments
        self.optionalFlags = optionalFlags
    }

    private static func makePath(
        actionWords: [String],
        arguments: [String],
        optionalFlags: [String]
    ) -> String {
        let parts = ["workspace"] + actionWords + arguments.map { "<\($0)>" } + optionalFlags.map { "[\($0)]" }
        return parts.joined(separator: " ")
    }
}

public struct IPCWindowActionDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let name: IPCWindowActionName
    public let summary: String
    public let arguments: [String]

    public init(
        path: String,
        name: IPCWindowActionName,
        summary: String,
        arguments: [String] = []
    ) {
        self.path = path
        self.name = name
        self.summary = summary
        self.arguments = arguments
    }
}

public struct IPCCaptureActionDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let name: IPCCaptureActionName
    public let summary: String
    public let arguments: [String]

    public init(
        path: String,
        name: IPCCaptureActionName,
        summary: String,
        arguments: [String] = []
    ) {
        self.path = path
        self.name = name
        self.summary = summary
        self.arguments = arguments
    }
}

public struct IPCRuleActionDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let name: IPCRuleActionName
    public let summary: String
    public let arguments: [String]
    public let options: [IPCRuleActionOptionDescriptor]

    public init(
        path: String,
        name: IPCRuleActionName,
        summary: String,
        arguments: [String] = [],
        options: [IPCRuleActionOptionDescriptor] = []
    ) {
        self.path = path
        self.name = name
        self.summary = summary
        self.arguments = arguments
        self.options = options
    }
}

public struct IPCRuleActionOptionDescriptor: Codable, Equatable, Sendable {
    public let flag: String
    public let summary: String
    public let valuePlaceholder: String?
    public let exclusiveGroup: String?

    public init(
        flag: String,
        summary: String,
        valuePlaceholder: String? = nil,
        exclusiveGroup: String? = nil
    ) {
        self.flag = flag
        self.summary = summary
        self.valuePlaceholder = valuePlaceholder
        self.exclusiveGroup = exclusiveGroup
    }
}

public struct IPCSubscriptionDescriptor: Codable, Equatable, Sendable {
    public let channel: IPCSubscriptionChannel
    public let summary: String
    public let resultKind: IPCResultKind

    public init(channel: IPCSubscriptionChannel, summary: String, resultKind: IPCResultKind) {
        self.channel = channel
        self.summary = summary
        self.resultKind = resultKind
    }
}

public enum IPCAutomationManifest {
    public static func commandDescriptor(for name: IPCCommandName) -> IPCCommandDescriptor? {
        commandDescriptors.first { $0.name == name }
    }

    public static func commandDescriptors(matching commandWords: [String]) -> [IPCCommandDescriptor] {
        commandDescriptors
            .sorted {
                if $0.commandWords.count != $1.commandWords.count {
                    return $0.commandWords.count > $1.commandWords.count
                }
                return $0.path < $1.path
            }
            .filter { descriptor in
                guard commandWords.count >= descriptor.commandWords.count else { return false }
                return Array(commandWords.prefix(descriptor.commandWords.count)) == descriptor.commandWords
            }
    }
}
