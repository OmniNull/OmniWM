// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum MonitorRanking {
    static func roleOrder(ranking: [OutputId], sortedMonitors: [Monitor]) -> [Monitor] {
        var ordered: [Monitor] = []
        visitRoleCandidates(ranking: ranking, sortedMonitors: sortedMonitors) { monitor in
            if !ordered.contains(where: { $0.id == monitor.id }) { ordered.append(monitor) }
            return false
        }
        return ordered
    }

    static func monitor(atRole index: Int, ranking: [OutputId], sortedMonitors: [Monitor]) -> Monitor? {
        var earlier = InlineArray<3, Monitor.ID?>(repeating: nil)
        guard earlier.indices.contains(index) else { return nil }
        var count = 0
        var result: Monitor?
        visitRoleCandidates(ranking: ranking, sortedMonitors: sortedMonitors) { monitor in
            for prior in 0 ..< count where earlier[prior] == monitor.id { return false }
            if count == index {
                result = monitor
                return true
            }
            earlier[count] = monitor.id
            count += 1
            return false
        }
        return result
    }

    private static func visitRoleCandidates(
        ranking: [OutputId], sortedMonitors: [Monitor], until done: (Monitor) -> Bool
    ) {
        for entry in ranking {
            if let monitor = resolve(entry, in: sortedMonitors), done(monitor) { return }
        }
        let main = sortedMonitors.first(where: \.isMain)
        if let main, done(main) { return }
        for monitor in sortedMonitors where monitor.id != main?.id {
            if done(monitor) { return }
        }
    }

    static func resolve(_ entry: OutputId, in monitors: [Monitor]) -> Monitor? {
        if let monitor = entry.resolveMonitor(in: monitors) {
            return monitor
        }
        guard entry.displayUUID == nil else { return nil }
        var match: Monitor?
        for monitor in monitors where Monitor.namesMatch(monitor.name, entry.name) {
            if match != nil { return nil }
            match = monitor
        }
        return match
    }

    static func effectiveRanks(ranking: [OutputId], monitors: [Monitor]) -> [Int?] {
        var seen: Set<Monitor.ID> = []
        var ranks: [Int?] = []
        for entry in ranking {
            guard let monitor = resolve(entry, in: monitors), !seen.contains(monitor.id) else {
                ranks.append(nil)
                continue
            }
            seen.insert(monitor.id)
            ranks.append(seen.count - 1)
        }
        return ranks
    }

    static func isConnected(_ entry: OutputId, monitors: [Monitor]) -> Bool {
        resolve(entry, in: monitors) != nil
    }

    static func normalized(_ ranking: [OutputId]) -> [OutputId] {
        var result: [OutputId] = []
        for entry in ranking {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let normalizedEntry = OutputId(displayUUID: entry.displayUUID, displayId: entry.displayId, name: name)
            guard !result.contains(where: { duplicates($0, normalizedEntry) }) else { continue }
            result.append(normalizedEntry)
        }
        return result
    }

    static func addable(connected monitors: [Monitor], ranking: [OutputId]) -> [OutputId] {
        let rankedIds = Set(ranking.compactMap { resolve($0, in: monitors)?.id })
        return Monitor.sortedByPosition(monitors)
            .filter { !rankedIds.contains($0.id) }
            .map(OutputId.init(from:))
    }

    static func roleName(forRank index: Int) -> String {
        switch index {
        case 0: String(localized: "Main")
        case 1: String(localized: "Secondary")
        case 2: String(localized: "Tertiary")
        default: String(localized: "Rank \(index + 1)")
        }
    }

    static func moving<Element>(_ items: [Element], from index: Int, by offset: Int) -> [Element] {
        let target = index + offset
        guard items.indices.contains(index), items.indices.contains(target), index != target else { return items }
        var result = items
        result.swapAt(index, target)
        return result
    }

    static func removing<Element>(_ items: [Element], at index: Int) -> [Element] {
        guard items.indices.contains(index) else { return items }
        var result = items
        result.remove(at: index)
        return result
    }

    private static func duplicates(_ lhs: OutputId, _ rhs: OutputId) -> Bool {
        if lhs.displayUUID != nil || rhs.displayUUID != nil {
            return lhs.displayUUID == rhs.displayUUID
        }
        return lhs.displayId == rhs.displayId && Monitor.namesMatch(lhs.name, rhs.name)
    }
}
