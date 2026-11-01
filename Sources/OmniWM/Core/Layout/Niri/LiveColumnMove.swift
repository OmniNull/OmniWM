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

        var width: CGFloat {
            maxX - minX
        }

        func contains(x: CGFloat) -> Bool {
            minX <= x && x < maxX
        }

        func isFullyVisible(in frame: CGRect) -> Bool {
            minX >= frame.minX - 0.5 && maxX <= frame.maxX + 0.5
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

    struct NarrowedSlot: Equatable {
        let columnId: NodeId
        let fullWidth: CGFloat
        var leftCut: CGFloat
    }

    enum SlotClosing: Equatable {
        case pickup(x: CGFloat)
        case following(edge: Side)
        case trailing
    }

    struct SlotLeads: Equatable {
        let left: CGFloat
        let right: CGFloat
    }

    struct Passed: Equatable {
        let columnId: NodeId
        let furthestX: CGFloat
        let wayBack: CGFloat

        func hasComeBack(at x: CGFloat) -> Bool {
            wayBack < 0 ? x <= furthestX + wayBack : x >= furthestX + wayBack
        }

        func extended(to x: CGFloat) -> Passed {
            .init(
                columnId: columnId,
                furthestX: wayBack < 0 ? max(furthestX, x) : min(furthestX, x),
                wayBack: wayBack
            )
        }
    }

    let windowId: NodeId
    let windowToken: WindowToken
    let workspaceId: WorkspaceDescriptor.ID
    let originalColumnOrder: [NodeId]
    let originalViewport: ViewportState
    let originalActiveColumnId: NodeId
    let originalViewPosition: CGFloat
    var phase: Phase = .dragging
    var hover: Hover?
    var dropSpaceId: NodeId?
    var dropSpaceKeepsStripEnd = false
    var lockedTarget: TargetLock?
    var edgeScrollSide: Side?
    var swapCount = 0
    var narrowedSlot: NarrowedSlot?
    var slotClosing: SlotClosing?
    var slotLeads: SlotLeads?
    var passed: Passed?
    var sideBySideIds: Set<NodeId> = []
}
