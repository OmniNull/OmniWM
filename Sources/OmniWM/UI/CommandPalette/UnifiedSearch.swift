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

    static func launcherTarget(_ targetID: String) -> Self {
        Self(rawValue: "launcher:\(targetID)")
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

    enum Line: Hashable {
        case topHitsHeading
        case groupHeading(CommandPaletteMode)
        case row(CommandPaletteSelectionID)
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

    var lines: [Line] {
        var lines: [Line] = topHits.isEmpty ? [] : [.topHitsHeading] + topHits.map(Line.row)
        for (group, rows) in zip(groups, sections.suffix(groups.count)) {
            lines.append(.groupHeading(group.mode))
            lines += rows.map(Line.row)
        }
        return lines
    }

    var isEmpty: Bool {
        topHits.isEmpty && groups.isEmpty
    }
}

enum PendingUnifiedSelection: Equatable {
    case current(CommandPaletteSelectionTrigger)
    case topHit(Int)
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

        var topHits = learnedTopHits(ranked, learnedPicks: learnedPicks)
        var chosen = Set(topHits)
        let openSlots = topHitLimit - topHits.count
        if openSlots > 0 {
            var closest: [(tier: MatchTier, id: CommandPaletteSelectionID)] = []
            for entry in ranked where !chosen.contains(entry.candidate.id) {
                if closest.count == openSlots, closest.last?.tier == .titlePrefix { break }
                let tier = matchTier(entry.candidate, foldedQuery: foldedQuery)
                guard closest.count < openSlots || tier < closest[closest.count - 1].tier else { continue }
                closest.insert((tier, entry.candidate.id), at: closest.firstIndex { tier < $0.tier } ?? closest.count)
                if closest.count > openSlots { closest.removeLast() }
            }
            topHits += closest.map(\.id)
            chosen.formUnion(closest.map(\.id))
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

    private static func learnedTopHits(
        _ ranked: [RankedCandidate],
        learnedPicks: [UnifiedSearchPickKey]
    ) -> [CommandPaletteSelectionID] {
        guard !learnedPicks.isEmpty else { return [] }
        let wanted = Set(learnedPicks)
        var strongestMatch: [UnifiedSearchPickKey: RankedCandidate] = [:]
        for entry in ranked {
            guard let key = entry.candidate.pickKey, wanted.contains(key) else { continue }
            if let current = strongestMatch[key], current.learnedPickTieBreak <= entry.learnedPickTieBreak { continue }
            strongestMatch[key] = entry
        }
        return learnedPicks.lazy.compactMap { strongestMatch[$0]?.candidate.id }.prefix(topHitLimit).map(\.self)
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
