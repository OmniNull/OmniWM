// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum MonitorRanking {
    static func roleOrder(ranking: [OutputId], sortedMonitors: [Monitor]) -> [Monitor] {
        var ordered: [Monitor] = []
        for entry in ranking {
            guard let monitor = resolve(entry, in: sortedMonitors),
                  !ordered.contains(where: { $0.id == monitor.id })
            else { continue }
            ordered.append(monitor)
        }
        for monitor in defaultOrder(sortedMonitors) where !ordered.contains(where: { $0.id == monitor.id }) {
            ordered.append(monitor)
        }
        return ordered
    }

    static func defaultOrder(_ sortedMonitors: [Monitor]) -> [Monitor] {
        guard let main = sortedMonitors.first(where: \.isMain) else { return sortedMonitors }
        return [main] + sortedMonitors.filter { $0.id != main.id }
    }

    static func resolve(_ entry: OutputId, in monitors: [Monitor]) -> Monitor? {
        if let monitor = entry.resolveMonitor(in: monitors) {
            return monitor
        }
        guard entry.displayUUID == nil else { return nil }
        let byName = monitors.filter { Monitor.namesMatch($0.name, entry.name) }
        return byName.count == 1 ? byName[0] : nil
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
