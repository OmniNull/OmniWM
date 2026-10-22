// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct InteractiveMove {
    let windowId: NodeId
    var windowToken: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let startMouseLocation: CGPoint
    let allowsInsertion: Bool
    let orientation: Monitor.Orientation

    var currentHoverTarget: MoveHoverTarget?
}

struct MoveHoverTarget: Equatable {
    let nodeId: NodeId
    let token: WindowToken
    let direction: Direction?
}

enum InsertPosition: Equatable {
    case before
    case after
    case swap
}

struct MoveConfiguration {
    var dragThreshold: CGFloat = 10.0
    var liveHoverDelay: TimeInterval = 0.2
    var liveSideBySideDepth: CGFloat = 20.0
    var liveWayBackShare: CGFloat = 1.0 / 3.0
    var liveWayBackMinimum: CGFloat = 60.0
    var liveDropSpaceShare: CGFloat = 0.05
    var liveDropSpaceMaximumWidth: CGFloat = 200.0
    var liveEdgeZoneShare: CGFloat = 0.03
    var liveEdgeZoneMinimumWidth: CGFloat = 40.0
    var liveEdgeScrollDelay: TimeInterval = 0.3
    var liveEdgeScrollSpeed: CGFloat = 1000.0

    static let `default` = MoveConfiguration()

    func liveEdgeZoneWidth(forDisplayWidth displayWidth: CGFloat) -> CGFloat {
        max(displayWidth * liveEdgeZoneShare, liveEdgeZoneMinimumWidth)
    }
}
