// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct UnifiedSearchPickHistory: Codable, Equatable, Sendable {
    struct Pick: Codable, Equatable, Sendable {
        var count: Int
        var lastPicked: Date
    }

    struct QueryPicks: Codable, Equatable, Sendable {
        var lastUsed: Date
        var picks: [UnifiedSearchPickKey: Pick]
    }

    static let queryLimit = 500
    static let picksPerQueryLimit = 32

    var queries: [String: QueryPicks] = [:]

    mutating func record(query: String, key: UnifiedSearchPickKey, date: Date) {
        let foldedQuery = Self.fold(query)
        guard !foldedQuery.isEmpty else { return }
        var entry = queries[foldedQuery] ?? QueryPicks(lastUsed: date, picks: [:])
        entry.lastUsed = date
        var pick = entry.picks[key] ?? Pick(count: 0, lastPicked: date)
        pick.count += 1
        pick.lastPicked = date
        entry.picks[key] = pick
        if entry.picks.count > Self.picksPerQueryLimit {
            let retained = entry.picks.sorted { $0.value.lastPicked > $1.value.lastPicked }
                .prefix(Self.picksPerQueryLimit)
            entry.picks = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        }
        queries[foldedQuery] = entry
        if queries.count > Self.queryLimit {
            let retained = queries.sorted { $0.value.lastUsed > $1.value.lastUsed }.prefix(Self.queryLimit)
            queries = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        }
    }

    func learnedPicksStrongestFirst(
        for query: String,
        launcherLaunches: [String: [LauncherLaunch]]
    ) -> [UnifiedSearchPickKey] {
        let foldedQuery = Self.fold(query)
        guard !foldedQuery.isEmpty else { return [] }
        var merged: [UnifiedSearchPickKey: Pick] = [:]
        func merge(_ key: UnifiedSearchPickKey, _ pick: Pick) {
            merged[key] = merged[key].map {
                Pick(count: $0.count + pick.count, lastPicked: max($0.lastPicked, pick.lastPicked))
            } ?? pick
        }
        for (storedQuery, entry) in queries where storedQuery.hasPrefix(foldedQuery) {
            for (key, pick) in entry.picks {
                merge(key, pick)
            }
        }
        for (targetID, launches) in launcherLaunches {
            let matching = launches.filter { Self.fold($0.foldedQuery).hasPrefix(foldedQuery) }
            guard let lastLaunch = matching.map(\.date).max() else { continue }
            merge(.launcherTarget(targetID), Pick(count: matching.count, lastPicked: lastLaunch))
        }
        return merged.sorted { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
            if lhs.value.lastPicked != rhs.value.lastPicked { return lhs.value.lastPicked > rhs.value.lastPicked }
            return lhs.key.rawValue < rhs.key.rawValue
        }
        .map(\.key)
    }

    private static func fold(_ query: String) -> String {
        UnifiedSearch.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
