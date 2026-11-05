// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
enum WorkspaceEntryOrdering {
    static func orderedEntries(
        _ entries: [WindowState],
        topology: LayoutTopology
    ) -> [WindowState] {
        guard topology.hasColumns, !entries.isEmpty else { return entries }

        var indexByToken: [WindowToken: Int] = [:]
        indexByToken.reserveCapacity(entries.count)
        for index in entries.indices {
            indexByToken[entries[index].token] = index
        }

        var ordered: [WindowState] = []
        ordered.reserveCapacity(entries.count)
        for column in topology.columns {
            for tile in column.tiles {
                if let index = indexByToken.removeValue(forKey: tile.token) {
                    ordered.append(entries[index])
                }
            }
        }
        guard !indexByToken.isEmpty else { return ordered }
        for index in entries.indices where indexByToken[entries[index].token] != nil {
            ordered.append(entries[index])
        }
        return ordered
    }
}
