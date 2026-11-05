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

    struct KeptWidths: Equatable {
        let manualColumnCount: Int?
    }

    struct Landing: Equatable {
        let columnId: NodeId
        let targetWindowId: NodeId
        let above: Bool
    }

    struct StackDrop: Equatable {
        let workspaceId: WorkspaceDescriptor.ID
        let windowId: NodeId
        let homeColumnId: NodeId
        let dropSpaceId: NodeId?
        let targetColumnId: NodeId
    }

    struct WindowSpan {
        let window: NiriWindow
        let minY: CGFloat
        let maxY: CGFloat

        func contains(y: CGFloat) -> Bool {
            minY <= y && y < maxY
        }
    }

    struct MateHeight: Equatable {
        let windowId: NodeId
        let height: WeightedSize
        let restsAtTop: Bool

        func apply(to window: NiriWindow) {
            window.height = height
            window.restAtTopAgain(restsAtTop)
        }
    }

    struct FreeArea: Equatable {
        let landing: Landing
        let height: CGFloat
    }

    enum StackChoice: Equatable {
        case keep
        case home
        case land(Landing)
    }

    struct StackProbe: Equatable {
        let columnId: NodeId?
        let cursor: CGPoint
        let wouldChange: Bool
    }

    struct WindowSizing: Equatable {
        let size: CGFloat
        let height: WeightedSize
        var restsAtTop = false

        func apply(to window: NiriWindow) {
            window.size = size
            window.height = height
            window.restAtTopAgain(restsAtTop)
        }
    }

    struct OriginalSlot: Equatable {
        let columnId: NodeId
        let index: Int
        let displayMode: ColumnDisplay
        let activeTileIdx: Int
        let windowSizing: WindowSizing
    }

    struct VisitedStrip {
        let workspaceId: WorkspaceDescriptor.ID
        let viewport: ViewportState
        let activeColumnId: NodeId?
    }

    struct WidenedColumn {
        let workspaceId: WorkspaceDescriptor.ID
        let columnId: NodeId
        let sizing: NiriContainerSizingState
    }

    struct Carry {
        let originalWorkspaceId: WorkspaceDescriptor.ID
        let originalOwnSizing: NiriContainerSizingState
        var parkedHomeColumn: NiriContainer?
        var visitedStrips: [VisitedStrip] = []
        var widenedColumn: WidenedColumn?
    }

    let windowId: NodeId
    let windowToken: WindowToken
    var workspaceId: WorkspaceDescriptor.ID
    var homeColumnId: NodeId
    let isWholeColumn: Bool
    let pullsTab: Bool
    var inStack: Bool
    var homeSlotIndex: Int
    let originalSlot: OriginalSlot
    var ownSizing: NiriContainerSizingState
    var ownWindowSizing: WindowSizing
    let originalColumnOrder: [NodeId]
    let originalViewport: ViewportState
    let originalActiveColumnId: NodeId
    var originalViewPosition: CGFloat
    var phase: Phase = .dragging
    var hover: Hover?
    var dropSpaceId: NodeId?
    var dropSpaceKeepsStripEnd = false
    var lockedTarget: TargetLock?
    var edgeScrollSide: Side?
    var stackMode = false
    var landing: Landing?
    var mateHeight: MateHeight?
    var keptWidths: KeptWidths?
    var stackSuppressPoint: CGPoint?
    var awaitsPointerMoveFrom: CGPoint?
    var floatingFrame: CGRect?
    var swapCount = 0
    var narrowedSlot: NarrowedSlot?
    var slotClosing: SlotClosing?
    var slotLeads: SlotLeads?
    var passed: Passed?
    var sideBySideIds: Set<NodeId> = []
    var carry: Carry?

    func isStill(at cursor: CGPoint) -> Bool {
        guard let still = awaitsPointerMoveFrom else { return false }
        return hypot(cursor.x - still.x, cursor.y - still.y) < 1
    }
}
