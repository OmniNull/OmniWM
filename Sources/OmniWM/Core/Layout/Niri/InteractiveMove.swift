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

    static let `default` = MoveConfiguration()

    static let liveHoverDelay: TimeInterval = 0.2
    static let liveSlowDownWindow: TimeInterval = 0.06
    static let liveSlowDownDistance: CGFloat = 6.0
    static let liveDropSpaceShare: CGFloat = 0.05
    static let liveDropSpaceMaximumWidth: CGFloat = 200.0
    static let liveEdgeZoneShare: CGFloat = 0.03
    static let liveEdgeZoneMinimumWidth: CGFloat = 40.0
    static let liveEdgeScrollDelay: TimeInterval = 0.3
    static let liveEdgeScrollSpeed: CGFloat = 1000.0
    static let liveEdgeHopInterval: TimeInterval = 0.5
    static let liveStackSuppressDistance: CGFloat = 30.0
    static let liveCentreMinimumWidth: CGFloat = 300.0
    static let liveStackLeaveOutsideShare: CGFloat = 0.4
    static let liveCentreStackDelay: TimeInterval = 0.2
    static let liveCentreExitMargin: CGFloat = 20.0
    static let liveLandingHintShare: CGFloat = 0.05
    static let liveLandingHintSingleWindowShare: CGFloat = 0.15
    static let liveLandingHintMinimumHeight: CGFloat = 40.0

    static func liveEdgeZoneWidth(forDisplayWidth displayWidth: CGFloat) -> CGFloat {
        max(displayWidth * liveEdgeZoneShare, liveEdgeZoneMinimumWidth)
    }
}
