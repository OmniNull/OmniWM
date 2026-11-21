// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

extension WorkspaceBarManager {
    static func workspacesRoom(
        beside slots: [WorkspaceBarShellWidget],
        length: CGFloat,
        zones: WorkspaceBarZones,
        scratchpads: CGFloat? = nil
    ) -> Double? {
        guard let index = slots.firstIndex(where: { $0.id == ShellConfig.bundledWorkspaces }) else { return nil }
        return Double(WorkspaceBarZoneLayout.room(
            for: index,
            among: slots.map { slot in
                let chosen = slot.id == ShellConfig.bundledScratchpads ? scratchpads : nil
                return .init(lane: slot.lane, length: chosen ?? slot.size.width, priority: slot.priority)
            },
            length: length,
            zones: zones
        ))
    }

    static func compactScratchpads(
        _ snapshot: WorkspaceBarSnapshot,
        beside slots: [WorkspaceBarShellWidget],
        availableWidth: CGFloat,
        icons: Int
    ) -> Set<Int> {
        let others = slots.filter { $0.id != ShellConfig.bundledScratchpads }
        let presented = WorkspaceBarScratchpadLayout.compactedItems(
            snapshot.scratchpads,
            widthBudget: .init(
                availableWidth: availableWidth,
                baseWidth: 8 + others.reduce(0) { $0 + $1.size.width } + CGFloat(max(0, others.count - 1)) * 8
            ),
            barHeight: snapshot.barHeight,
            icons: icons,
            hasAdjacentContent: !others.isEmpty
        )
        return Set(presented.filter { $0.presentation == .compact }.map(\.index))
    }
}
