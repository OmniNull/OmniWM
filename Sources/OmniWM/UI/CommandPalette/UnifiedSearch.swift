// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct UnifiedSearchPickKey: RawRepresentable, Hashable, Codable, CodingKeyRepresentable, Sendable {
    let rawValue: String

    static func window(bundleID: String) -> Self {
        Self(rawValue: "window:\(bundleID)")
    }

    static func command(actionID: String) -> Self {
        Self(rawValue: "command:\(actionID)")
    }

    static func application(bundleID: String) -> Self {
        Self(rawValue: "application:\(bundleID)")
    }

    static func launcherEntry(_ id: UUID) -> Self {
        Self(rawValue: "launcherEntry:\(id.uuidString)")
    }

    static func file(path: String) -> Self {
        Self(rawValue: "file:\(path)")
    }

    static func menuItem(bundleID: String, path: String) -> Self {
        Self(rawValue: "menu:\(bundleID):\(path)")
    }
}

struct UnifiedSearchCandidate: Equatable {
    let id: CommandPaletteSelectionID
    let title: String
    var otherFields: [String] = []
    var pickKey: UnifiedSearchPickKey?
    var focusRecency: Int?
}

struct UnifiedSearchResults: Equatable {
    struct Group: Equatable {
        let mode: CommandPaletteMode
        let rows: [CommandPaletteSelectionID]
        let hasMore: Bool
    }

    var topHits: [CommandPaletteSelectionID] = []
    var groups: [Group] = []

    var selectionOrder: [CommandPaletteSelectionID] {
        sections.flatMap(\.self)
    }

    var sections: [[CommandPaletteSelectionID]] {
        var sections: [[CommandPaletteSelectionID]] = topHits.isEmpty ? [] : [topHits]
        for group in groups {
            sections.append(group.rows + (group.hasMore ? [.showAll(group.mode)] : []))
        }
        return sections
    }

    var isEmpty: Bool {
        topHits.isEmpty && groups.isEmpty
    }
}

enum UnifiedSearch {
    static let topHitLimit = 3
    static let groupRowLimit = 5

    private enum MatchTier: Int, Comparable {
        case titlePrefix
        case titleWordPrefix
        case titleContains
        case otherFieldContains
        case noLiteralMatch

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private struct RankedCandidate {
        let candidate: UnifiedSearchCandidate
        let modeIndex: Int
        let rankIndex: Int

        var learnedPickTieBreak: (Int, Int) {
            (candidate.focusRecency ?? rankIndex, modeIndex)
        }

        var modeOrder: (Int, Int) {
            (modeIndex, rankIndex)
        }
    }

    static func compose(
        query: String,
        searchedModes: [CommandPaletteMode],
        results: [CommandPaletteMode: [UnifiedSearchCandidate]],
        learnedPicks: [UnifiedSearchPickKey],
        keepingVisible selectedID: CommandPaletteSelectionID? = nil
    ) -> UnifiedSearchResults {
        let foldedQuery = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !foldedQuery.isEmpty else { return UnifiedSearchResults() }

        let ranked = searchedModes.enumerated().flatMap { modeIndex, mode in
            (results[mode] ?? []).enumerated().map {
                RankedCandidate(candidate: $1, modeIndex: modeIndex, rankIndex: $0)
            }
        }

        var topHits: [CommandPaletteSelectionID] = []
        var chosen = Set<CommandPaletteSelectionID>()

        for key in learnedPicks where topHits.count < topHitLimit {
            let match = ranked
                .filter { $0.candidate.pickKey == key && !chosen.contains($0.candidate.id) }
                .min { $0.learnedPickTieBreak < $1.learnedPickTieBreak }
            guard let match else { continue }
            topHits.append(match.candidate.id)
            chosen.insert(match.candidate.id)
        }

        if topHits.count < topHitLimit {
            let unchosen: [(entry: RankedCandidate, tier: MatchTier)] = ranked
                .filter { !chosen.contains($0.candidate.id) }
                .map { (entry: $0, tier: matchTier($0.candidate, foldedQuery: foldedQuery)) }
            let fallback = unchosen.sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                return lhs.entry.modeOrder < rhs.entry.modeOrder
            }
            .prefix(topHitLimit - topHits.count)
            for item in fallback {
                topHits.append(item.entry.candidate.id)
                chosen.insert(item.entry.candidate.id)
            }
        }

        let groups = searchedModes.compactMap { mode -> UnifiedSearchResults.Group? in
            let remaining = (results[mode] ?? []).map(\.id).filter { !chosen.contains($0) }
            guard !remaining.isEmpty else { return nil }
            var rows = Array(remaining.prefix(groupRowLimit))
            if let selectedID, !rows.contains(selectedID), remaining.contains(selectedID) {
                rows[rows.count - 1] = selectedID
            }
            return UnifiedSearchResults.Group(mode: mode, rows: rows, hasMore: remaining.count > rows.count)
        }

        return UnifiedSearchResults(topHits: topHits, groups: groups)
    }

    private static func matchTier(_ candidate: UnifiedSearchCandidate, foldedQuery: String) -> MatchTier {
        let title = fold(candidate.title)
        if title.hasPrefix(foldedQuery) { return .titlePrefix }
        let words = title.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(foldedQuery) }) { return .titleWordPrefix }
        if title.contains(foldedQuery) { return .titleContains }
        if candidate.otherFields.contains(where: { fold($0).contains(foldedQuery) }) { return .otherFieldContains }
        return .noLiteralMatch
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
