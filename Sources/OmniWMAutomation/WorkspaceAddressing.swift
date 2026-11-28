// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

public enum WorkspaceIDPolicy {
    public static func normalizeRawID(_ candidate: String) -> String? {
        guard let value = Int(candidate), value > 0 else { return nil }
        let normalized = String(value)
        guard normalized == candidate else { return nil }
        return normalized
    }

    public static func rawID(from workspaceNumber: Int) -> String? {
        guard workspaceNumber > 0 else { return nil }
        return String(workspaceNumber)
    }

    public static func workspaceNumber(from rawID: String) -> Int? {
        guard let normalized = normalizeRawID(rawID) else { return nil }
        return Int(normalized)
    }

    public static func lowestUnusedRawID<S: Sequence>(in rawIDs: S) -> String where S.Element == String {
        let usedNumbers = Set(rawIDs.compactMap(workspaceNumber(from:)))
        var candidate = 1
        while usedNumbers.contains(candidate) {
            candidate += 1
        }
        return String(candidate)
    }

    public static func sortsBefore(_ lhs: String, _ rhs: String) -> Bool {
        switch (workspaceNumber(from: lhs), workspaceNumber(from: rhs)) {
        case let (lhs?, rhs?):
            return lhs < rhs
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

public enum WorkspaceTarget: Equatable, Sendable {
    case rawID(String)
    case displayName(String)

    public init(resolvingInput value: String) {
        if let rawID = WorkspaceIDPolicy.normalizeRawID(value) {
            self = .rawID(rawID)
        } else {
            self = .displayName(value)
        }
    }

    public init?(workspaceNumber: Int) {
        guard let rawID = WorkspaceIDPolicy.rawID(from: workspaceNumber) else { return nil }
        self = .rawID(rawID)
    }
}
