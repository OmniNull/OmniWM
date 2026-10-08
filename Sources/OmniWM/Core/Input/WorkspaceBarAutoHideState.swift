// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct WorkspaceBarAutoHideTarget {
    let id: Monitor.ID
    let monitorFrame: CGRect
    let activationRegions: [CGRect]
    let retentionRegions: [CGRect]
    var isVisible: Bool
    var isPinned: Bool

    init(monitor: Monitor, frames: [CGRect], resolved: ResolvedBarSettings, isVisible: Bool, isPinned: Bool) {
        id = monitor.id
        monitorFrame = monitor.frame
        self.isVisible = isVisible
        self.isPinned = isPinned
        let geometry = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
        let regions = frames.map { geometry.autoHideRegions(frame: $0, monitor: monitor, resolved: resolved) }
        activationRegions = regions.map(\.activation)
        retentionRegions = regions.map(\.retention)
    }

    func activates(_ pointer: CGPoint) -> Bool {
        contains(pointer, in: activationRegions)
    }

    func retains(_ pointer: CGPoint) -> Bool {
        contains(pointer, in: retentionRegions)
    }

    private func contains(_ pointer: CGPoint, in regions: [CGRect]) -> Bool {
        guard (monitorFrame.minX ..< monitorFrame.maxX).contains(pointer.x),
              pointer.y > monitorFrame.minY, pointer.y <= monitorFrame.maxY
        else { return false }
        return regions.contains {
            !$0.isEmpty && ($0.minX ... $0.maxX).contains(pointer.x) && ($0.minY ... $0.maxY).contains(pointer.y)
        }
    }
}

struct WorkspaceBarAutoHideState {
    private(set) var revealed: Set<Monitor.ID> = []

    mutating func update(targets: [WorkspaceBarAutoHideTarget], pointer: CGPoint) {
        revealed = Set(targets.filter { target in
            target.activates(pointer)
                || ((revealed.contains(target.id) || target.isVisible)
                    && (target.isPinned || target.retains(pointer)))
        }.map(\.id))
    }

    mutating func reset() {
        revealed = []
    }
}
