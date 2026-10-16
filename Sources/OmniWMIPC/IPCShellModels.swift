// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

public enum IPCShellActionName: String, Codable, CaseIterable, Equatable, Sendable {
    case set
    case unset
    case toggle
    case profile
    case theme
    case eject
    case initialize = "init"
    case trigger
}

public enum IPCShellRequest: Equatable, Sendable {
    case set(key: String, value: String)
    case unset(key: String)
    case toggle(widget: String)
    case profile(name: String)
    case theme(name: String, scheme: String?)
    case eject(widget: String)
    case initialize(widget: String)
    case trigger(widget: String, name: String, value: String?)

    public static let keyLimit = 64
    public static let valueLimit = 4096
    public static let countLimit = 64

    public var name: IPCShellActionName {
        switch self {
        case .set: .set
        case .unset: .unset
        case .toggle: .toggle
        case .profile: .profile
        case .theme: .theme
        case .eject: .eject
        case .initialize: .initialize
        case .trigger: .trigger
        }
    }

    public var key: String {
        switch self {
        case let .set(key, _),
             let .unset(key),
             let .toggle(key),
             let .profile(key),
             let .theme(key, _),
             let .eject(key),
             let .initialize(key),
             let .trigger(_, key, _): key
        }
    }

    public var isValid: Bool {
        switch self {
        case let .toggle(widget):
            return !widget.isEmpty && widget.utf8.count <= Self.keyLimit
        case let .eject(name):
            guard !name.isEmpty, name.utf8.count <= Self.keyLimit, !name.contains("\\") else { return false }
            if name.hasPrefix("lib/") {
                return name.split(separator: "/", omittingEmptySubsequences: false)
                    .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            }
            return !name.hasPrefix(".") && !name.contains("/")
        case let .profile(name),
             let .theme(name, nil):
            return !name.isEmpty && name.utf8.count <= Self.keyLimit && !name.hasPrefix(".") && !name.contains("/")
        case let .theme(name, scheme?):
            return Self.theme(name: name, scheme: nil).isValid && !scheme.isEmpty && scheme.utf8.count <= Self.keyLimit
        case let .initialize(name):
            return !name.isEmpty && name.utf8.count <= Self.keyLimit && name.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
            }
        case let .trigger(widget, _, value):
            guard !widget.isEmpty, widget.utf8.count <= Self.keyLimit, !widget.hasPrefix("."), !widget.contains("/"),
                  (value?.utf8.count ?? 0) <= Self.valueLimit
            else {
                return false
            }
        case .set,
             .unset:
            break
        }
        let keyIsValid = !key.isEmpty && key.utf8.count <= Self.keyLimit && key.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == ".")
        }
        guard keyIsValid else { return false }
        if case let .set(_, value) = self {
            return value.utf8.count <= Self.valueLimit
        }
        return true
    }
}

extension IPCShellRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case key
        case value
        case widget
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(IPCShellActionName.self, forKey: .name) {
        case .toggle:
            self = try .toggle(widget: container.decode(String.self, forKey: .widget))
        case .eject:
            self = try .eject(widget: container.decode(String.self, forKey: .widget))
        case .initialize:
            self = try .initialize(widget: container.decode(String.self, forKey: .widget))
        case .trigger:
            self = try .trigger(
                widget: container.decode(String.self, forKey: .widget),
                name: container.decode(String.self, forKey: .key),
                value: container.decodeIfPresent(String.self, forKey: .value)
            )
        case .profile:
            self = try .profile(name: container.decode(String.self, forKey: .key))
        case .theme:
            self = try .theme(
                name: container.decode(String.self, forKey: .key),
                scheme: container.decodeIfPresent(String.self, forKey: .value)
            )
        case .set:
            let key = try container.decode(String.self, forKey: .key)
            guard let value = try container.decodeIfPresent(String.self, forKey: .value) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.value,
                    .init(codingPath: container.codingPath, debugDescription: "set requires a value")
                )
            }
            self = .set(key: key, value: value)
        case .unset:
            let key = try container.decode(String.self, forKey: .key)
            guard try container.decodeIfPresent(String.self, forKey: .value) == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "unset does not accept a value"
                )
            }
            self = .unset(key: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        switch self {
        case let .set(key, value):
            try container.encode(key, forKey: .key)
            try container.encode(value, forKey: .value)
        case let .unset(key):
            try container.encode(key, forKey: .key)
        case let .toggle(widget),
             let .eject(widget),
             let .initialize(widget):
            try container.encode(widget, forKey: .widget)
        case let .profile(name):
            try container.encode(name, forKey: .key)
        case let .theme(name, scheme):
            try container.encode(name, forKey: .key)
            try container.encodeIfPresent(scheme, forKey: .value)
        case let .trigger(widget, name, value):
            try container.encode(widget, forKey: .widget)
            try container.encode(name, forKey: .key)
            try container.encodeIfPresent(value, forKey: .value)
        }
    }
}

public struct IPCShellActionDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let name: IPCShellActionName
    public let summary: String
    public let arguments: [String]

    public init(path: String, name: IPCShellActionName, summary: String, arguments: [String] = []) {
        self.path = path
        self.name = name
        self.summary = summary
        self.arguments = arguments
    }
}

public struct IPCShellWidget: Codable, Equatable, Sendable {
    public let name: String
    public let source: String
    public let state: String
    public let error: String?
    public let placements: [String]

    public init(name: String, source: String, state: String, error: String?, placements: [String]) {
        self.name = name
        self.source = source
        self.state = state
        self.error = error
        self.placements = placements
    }
}

public struct IPCShellWidgetsQueryResult: Codable, Equatable, Sendable {
    public let profile: String
    public let widgets: [IPCShellWidget]
    public let problems: [String]

    public init(profile: String, widgets: [IPCShellWidget], problems: [String] = []) {
        self.profile = profile
        self.widgets = widgets
        self.problems = problems
    }
}
