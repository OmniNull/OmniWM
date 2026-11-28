// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation

extension WorkspaceTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case rawID = "raw-id"
        case displayName = "display-name"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)

        switch kind {
        case .rawID:
            self = .rawID(WorkspaceIDPolicy.normalizeRawID(value) ?? value)
        case .displayName:
            self = .displayName(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .rawID(rawID):
            try container.encode(Kind.rawID, forKey: .kind)
            try container.encode(rawID, forKey: .value)
        case let .displayName(displayName):
            try container.encode(Kind.displayName, forKey: .kind)
            try container.encode(displayName, forKey: .value)
        }
    }
}
