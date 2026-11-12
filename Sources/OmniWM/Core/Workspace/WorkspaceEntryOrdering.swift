// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
enum WorkspaceEntryOrdering {
    static func orderedEntries(
        _ entries: consuming [WindowState],
        topology: LayoutTopology
    ) -> [WindowState] {
        guard topology.hasColumns, !entries.isEmpty else { return entries }
        var order = orderedIndices(entries.indices, in: entries, topology: topology)
        for start in order.indices where order[start] != start {
            var current = start
            while order[current] != start {
                let source = order[current]
                order[current] = current
                entries.swapAt(current, source)
                current = source
            }
            order[current] = current
        }
        return entries
    }

    static func orderedIndices(
        _ indices: some Collection<Int>,
        in entries: [WindowState],
        topology: LayoutTopology
    ) -> [Int] {
        guard topology.hasColumns, !indices.isEmpty else { return Array(indices) }

        var indexByToken: [WindowToken: Int] = [:]
        indexByToken.reserveCapacity(indices.count)
        for index in indices {
            indexByToken[entries[index].token] = index
        }

        var ordered: [Int] = []
        ordered.reserveCapacity(indices.count)
        for column in topology.columns {
            for tile in column.tiles {
                if let index = indexByToken.removeValue(forKey: tile.token) {
                    ordered.append(index)
                }
            }
        }
        guard !indexByToken.isEmpty else { return ordered }
        for index in indices where indexByToken[entries[index].token] != nil {
            ordered.append(index)
        }
        return ordered
    }
}
