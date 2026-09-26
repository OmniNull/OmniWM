// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

public enum IPCWindowMarkActionName: String, Codable, CaseIterable, Equatable, Sendable {
    case set
    case list
    case focus
    case summon
    case remove
}

public enum IPCWindowMarkRequest: Equatable, Sendable {
    case set(name: String)
    case list
    case focus(name: String)
    case summon(name: String)
    case remove(name: String)

    public var name: IPCWindowMarkActionName {
        switch self {
        case .set:
            .set
        case .list:
            .list
        case .focus:
            .focus
        case .summon:
            .summon
        case .remove:
            .remove
        }
    }
}

extension IPCWindowMarkRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case mark
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let action = try container.decode(IPCWindowMarkActionName.self, forKey: .name)
        let mark = try container.decodeIfPresent(String.self, forKey: .mark)

        switch action {
        case .set:
            guard let mark else {
                throw DecodingError.keyNotFound(
                    CodingKeys.mark,
                    .init(codingPath: container.codingPath, debugDescription: "set requires a mark name")
                )
            }
            self = .set(name: mark)
        case .list:
            guard mark == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .mark,
                    in: container,
                    debugDescription: "list does not accept a mark name"
                )
            }
            self = .list
        case .focus:
            guard let mark else {
                throw DecodingError.keyNotFound(
                    CodingKeys.mark,
                    .init(codingPath: container.codingPath, debugDescription: "focus requires a mark name")
                )
            }
            self = .focus(name: mark)
        case .summon:
            guard let mark else {
                throw DecodingError.keyNotFound(
                    CodingKeys.mark,
                    .init(codingPath: container.codingPath, debugDescription: "summon requires a mark name")
                )
            }
            self = .summon(name: mark)
        case .remove:
            guard let mark else {
                throw DecodingError.keyNotFound(
                    CodingKeys.mark,
                    .init(codingPath: container.codingPath, debugDescription: "remove requires a mark name")
                )
            }
            self = .remove(name: mark)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        switch self {
        case let .set(mark),
             let .focus(mark),
             let .summon(mark),
             let .remove(mark):
            try container.encode(mark, forKey: .mark)
        case .list:
            break
        }
    }
}

public struct IPCWindowMarkEntry: Codable, Equatable, Sendable {
    public let name: String
    public let workspace: IPCWorkspaceRef
    public let app: IPCAppRef
    public let title: String?

    public init(name: String, workspace: IPCWorkspaceRef, app: IPCAppRef, title: String?) {
        self.name = name
        self.workspace = workspace
        self.app = app
        self.title = title
    }
}

public struct IPCWindowMarksResult: Codable, Equatable, Sendable {
    public let marks: [IPCWindowMarkEntry]

    public init(marks: [IPCWindowMarkEntry]) {
        self.marks = marks
    }
}

public struct IPCWindowMarkActionDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let name: IPCWindowMarkActionName
    public let summary: String
    public let arguments: [String]

    public init(path: String, name: IPCWindowMarkActionName, summary: String, arguments: [String] = []) {
        self.path = path
        self.name = name
        self.summary = summary
        self.arguments = arguments
    }
}
