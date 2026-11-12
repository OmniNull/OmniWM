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
        case changedWhileHovering(until: TimeInterval)

        var changesLayout: Bool {
            switch self {
            case .changed,
                 .changedWhileHovering: true
            case .unchanged,
                 .hovering: false
            }
        }

        var hoverDeadline: TimeInterval? {
            switch self {
            case let .hovering(until),
                 let .changedWhileHovering(until): until
            case .unchanged,
                 .changed: nil
            }
        }
    }

    enum Side: Equatable {
        case before
        case after
    }

    struct SlotResize {
        let home: NiriContainer
        let placed: StripColumn
        let minX: CGFloat
        let width: CGFloat
    }

    struct Reorder {
        enum Kind {
            case closeDropSpace(NiriContainer, revealsHome: Bool)
            case openDropSpace(existing: NiriContainer?, beside: NiriContainer)
        }

        let dragged: NiriContainer
        let target: NiriContainer
        let side: Side
        let pinned: NiriContainer
        let kind: Kind
    }

    enum Action {
        case nothing
        case hovering(until: TimeInterval)
        case leaveStack(towardTrailingSide: Bool)
        case moveInStack(NiriWindow, home: NiriContainer, index: Int)
        case closeHint
        case showHint(LandingSlot)
        case switchHint(columnId: NodeId, dwellSince: TimeInterval?)
        case reorder(Reorder)

        var passiveStep: Step? {
            switch self {
            case .nothing: .unchanged
            case let .hovering(until): .hovering(until: until)
            case .leaveStack,
                 .moveInStack,
                 .closeHint,
                 .showHint,
                 .switchHint,
                 .reorder: nil
            }
        }
    }

    struct Decision {
        var move: LiveColumnMove
        let pointer: Pointer
        let strip: [StripColumn]
        var closing: SlotResize?
        var action: Action = .nothing

        var passiveStep: Step? {
            guard closing == nil else { return nil }
            return action.passiveStep
        }
    }

    struct Dwell: Equatable {
        enum Region: Equatable {
            case side(Side)
            case centre
        }

        let columnId: NodeId
        let region: Region
        let since: TimeInterval

        func start(on columnId: NodeId, in region: Region) -> TimeInterval? {
            self.columnId == columnId && self.region == region ? since : nil
        }
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

    struct KeptWidths: Equatable {
        let manualColumnCount: Int?
    }

    struct LandingSlot: Equatable {
        let columnId: NodeId
        let targetWindowId: NodeId
        let above: Bool
    }

    enum Home: Equatable {
        case origin
        case stackSlot
    }

    struct PointerHold: Equatable {
        let point: CGPoint

        func holds(at cursor: CGPoint) -> Bool {
            hypot(cursor.x - point.x, cursor.y - point.y) < MoveConfiguration.liveStackSuppressDistance
        }
    }

    struct StackDrop: Equatable {
        let workspaceId: WorkspaceDescriptor.ID
        let windowId: NodeId
        let homeColumnId: NodeId
        let dropSpaceId: NodeId?
        let targetColumnId: NodeId
        var originalViewPosition: CGFloat?
    }

    struct WindowSpan {
        let window: NiriWindow
        let minY: CGFloat
        let maxY: CGFloat

        func contains(y: CGFloat) -> Bool {
            minY <= y && y < maxY
        }

        func distance(toY y: CGFloat) -> CGFloat {
            max(minY - y, y - maxY, 0)
        }
    }

    struct MateHeight: Equatable {
        let windowId: NodeId
        let height: WeightedSize

        func apply(to window: NiriWindow) {
            window.height = height
        }
    }

    enum StackChoice: Equatable {
        case keep
        case home
        case land(LandingSlot)
    }

    struct Pointer {
        let cursor: CGPoint
        let time: TimeInterval?
        var slowed = false
    }

    struct WindowSizing: Equatable {
        let size: CGFloat
        let height: WeightedSize

        func apply(to window: NiriWindow) {
            window.size = size
            window.height = height
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
    var home: Home
    var homeSlotIndex: Int
    let originalSlot: OriginalSlot
    var ownSizing: NiriContainerSizingState
    var ownWindowSizing: WindowSizing
    let originalColumnOrder: [NodeId]
    let originalViewport: ViewportState
    let originalActiveColumnId: NodeId
    var originalViewPosition: CGFloat
    var phase: Phase = .dragging
    var dwell: Dwell?
    var dropSpaceId: NodeId?
    var heading: Side?
    var headingFromX: CGFloat?
    var lockedTarget: TargetLock?
    var edgeScrollSide: Side?
    var pointerInEdgeZone = false
    var heldTabs: [NiriWindow] = []
    var pulledStripEnd: Side?
    var originClosedToward: Side?
    var landing: LandingSlot?
    var mateHeight: MateHeight?
    var keptWidths: KeptWidths?
    var pointerHold: PointerHold?
    var floatingFrame: CGRect?
    var narrowedSlot: NarrowedSlot?
    var carry: Carry?

    mutating func endSideDwell() {
        if dwell?.region != .centre {
            dwell = nil
        }
    }

    mutating func endCentreDwell() {
        if dwell?.region == .centre {
            dwell = nil
        }
    }

    mutating func setHome(columnId: NodeId, inStack: Bool) {
        homeColumnId = columnId
        home = inStack ? .stackSlot : .origin
    }
}
