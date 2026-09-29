// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct WorkspaceBarAutoHideTarget {
    let id: Monitor.ID
    let activationRegions: [CGRect]
    let retentionRegions: [CGRect]
    let isVisible: Bool
    let isPinned: Bool

    init(monitor: Monitor, frames: [CGRect], position: WorkspaceBarPosition, isVisible: Bool, isPinned: Bool) {
        id = monitor.id
        self.isVisible = isVisible
        self.isPinned = isPinned
        activationRegions = frames.map { frame in
            let edge: CGRect = switch position {
            case .overlappingMenuBar,
                 .belowMenuBar:
                CGRect(x: frame.minX, y: monitor.frame.maxY - 1, width: frame.width, height: 1)
            case .bottom:
                CGRect(x: frame.minX, y: monitor.visibleFrame.minY, width: frame.width, height: 1)
            case .left:
                CGRect(x: monitor.visibleFrame.minX, y: frame.minY, width: 1, height: frame.height)
            case .right:
                CGRect(x: monitor.visibleFrame.maxX - 1, y: frame.minY, width: 1, height: frame.height)
            }
            return frame.union(edge).insetBy(dx: -8, dy: -8).intersection(monitor.frame)
        }
        retentionRegions = frames.map {
            $0.insetBy(dx: -20, dy: -20).intersection(monitor.frame)
        } + activationRegions
    }
}

struct WorkspaceBarAutoHideState {
    private(set) var revealed: Set<Monitor.ID> = []

    mutating func update(targets: [WorkspaceBarAutoHideTarget], pointer: CGPoint) {
        revealed = Set(targets.filter { target in
            target.activationRegions.contains { $0.contains(pointer) }
                || ((revealed.contains(target.id) || target.isVisible)
                    && (target.isPinned || target.retentionRegions.contains { $0.contains(pointer) }))
        }.map(\.id))
    }

    mutating func reset() {
        revealed = []
    }
}
