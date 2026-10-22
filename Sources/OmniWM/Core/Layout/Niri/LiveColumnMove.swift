// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct LiveColumnMove {
    enum Phase: Equatable {
        case dragging
        case settling
    }

    struct StripColumn {
        let column: NiriContainer
        let minX: CGFloat
        let maxX: CGFloat

        var midX: CGFloat {
            (minX + maxX) / 2
        }

        func contains(x: CGFloat) -> Bool {
            minX <= x && x < maxX
        }
    }

    enum Step: Equatable {
        case unchanged
        case hovering(until: TimeInterval)
        case changed
    }

    enum Side: Equatable {
        case before
        case after
    }

    struct Hover: Equatable {
        let columnId: NodeId
        let side: Side
        let since: TimeInterval
    }

    struct TargetLock: Equatable {
        let columnId: NodeId
        let side: Side
    }

    let windowId: NodeId
    let windowToken: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let ownSizing: NiriContainerSizingState
    let originalColumnOrder: [NodeId]
    let originalViewport: ViewportState
    let originalActiveColumnId: NodeId
    let originalViewPosition: CGFloat
    var phase: Phase = .dragging
    var hover: Hover?
    var dropSpaceId: NodeId?
    var lockedTarget: TargetLock?
    var swapCount = 0
}
