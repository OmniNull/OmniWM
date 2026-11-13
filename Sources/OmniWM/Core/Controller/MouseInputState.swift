// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

let niriWheelScrollTickAmount: CGFloat = 120.0

struct MouseInputState {
    enum InteractionSource: Hashable {
        case mouse(MouseEventHandler.MouseButton)
        case trackpadGesture

        var mouseButton: MouseEventHandler.MouseButton? {
            if case let .mouse(button) = self { button } else { nil }
        }
    }

    struct LockedGestureContext {
        let workspaceId: WorkspaceDescriptor.ID
        let monitorId: Monitor.ID
        let fingerCount: Int
        let columnScrollCandidate: Bool
        let columnScrollAxis: WorkspaceSwipeAxis
        let workspaceAxis: WorkspaceSwipeAxis?
        let overviewAction: OverviewGestureAction?
        let windowGestureTarget: WindowToken?
        let startLocation: CGPoint
        var contactSession: MultitouchContactSession?
    }

    enum GesturePhase {
        case idle
        case armed
        case committed
    }

    enum NativeTitleBarDragPhase: Equatable {
        case armed
        case dragging
        case awaitingFrameChange
        case awaitingFrameWrite
        case awaitingCorrection
        case settlingResize
    }

    struct NativeResizeSettling {
        let releasedAt: TimeInterval
        let target: CGSize
    }

    struct NativeTitleBarDrag: Equatable {
        let token: WindowToken
        var phase: NativeTitleBarDragPhase = .armed
        var targetWasRejected = false
        var receivedFrameChange = false
        var pendingExcludedCorrection = false
        var issuedUnreadableCorrection = false
        var terminalFailureRetryRequestId: AXFrameRequestId?
        var adoptionStartFrame: CGRect?
        var pendingWriteStartFrame: CGRect?
        var lateResize = false
        var liveStartFrame: CGRect?
        var dwindleResizeWorkspaceId: WorkspaceDescriptor.ID?
        var liveDrag = false
        var liveDragDeclined = false
        var liveDragHandedOver = false
    }

    struct LiveEdgeScroll {
        enum Edge: Equatable {
            case leading
            case trailing
        }

        let edge: Edge
        let workspaceId: WorkspaceDescriptor.ID
        let enteredAt: TimeInterval
        var delayTimer: Timer?
        var isScrolling = false
        var hopping = false
        var hopsDone = false
        var strip: (columns: [LiveColumnMove.StripColumn], viewOffset: CGFloat)?
        var stripContext: NiriInteractionContext?
    }

    struct LiveEdgeZoneHold {
        let edge: LiveEdgeScroll.Edge
        let x: CGFloat

        func isPassed(by location: CGPoint) -> Bool {
            edge == .leading ? location.x < x : location.x > x
        }
    }

    struct LivePointerSample {
        let location: CGPoint
        let time: TimeInterval
    }

    struct LiveTabPull {
        let token: WindowToken
        let anchorLocation: CGPoint
        let startFrame: CGRect
    }

    struct LiveDropScroll {
        let token: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
    }

    struct NativeResizeStart {
        let token: WindowToken
        let frame: CGRect
        let location: CGPoint
        var wasDragged = false
        var hasDeferredFrameChange = false
    }

    struct NativeResizeCorrection {
        let token: WindowToken
        var issuedUnreadableCorrection = false
        var needsFrameWriteRecheck = false
        var issuedTerminalFailureCorrection = false
    }

    struct NativeCrossDisplayMove {
        let token: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
        let startFrame: CGRect
        var wasDragged = false
        var releaseLocation: CGPoint?
    }

    struct FocusFollowsMouseSample {
        let location: CGPoint
        let modifiersRawValue: UInt64
        let windowIdUnderPointer: Int?
    }

    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var eventTapRunLoop: CFRunLoop?
    var moveTap: CFMachPort?
    var moveTapRunLoopSource: CFRunLoopSource?
    var moveTapDeliversMouseMoved = false
    var currentHoveredEdges: ResizeEdge = []
    var isResizing: Bool = false
    var isMoving: Bool = false
    var liveDragTracedDecline: String?
    var liveDropScroll: LiveDropScroll?
    var deferredClickScroll: WindowToken?
    var fusionDoubleClickWidths: [NodeId: FusionDoubleClickWidth] = [:]
    var liveDragLayoutStart: NiriLayoutChangeStart?
    var activeInteractionSource: InteractionSource?
    var activeInteractionButton: MouseEventHandler.MouseButton? {
        get { activeInteractionSource?.mouseButton }
        set { activeInteractionSource = newValue.map { .mouse($0) } }
    }

    var gestureOwnsWindowInteraction: Bool {
        activeInteractionSource == .trackpadGesture
    }

    var capturedInteractionButton: MouseEventHandler.MouseButton?
    var capturedOtherMouseButton: Int64?
    var parkingEdgePressButton: MouseEventHandler.MouseButton?
    var resizeLayout: LayoutType?
    var moveLayout: LayoutType?
    var awaitsNativeTitleBarDragTarget = false
    var nativeTitleBarDragPressTimestamp: CGEventTimestamp?
    var nativeTitleBarDragFallbackToken: WindowToken?
    var nativeTitleBarDragFallbackReleased = false
    var nativeTitleBarDrag: NativeTitleBarDrag?
    var nativeResizeSettling: NativeResizeSettling?
    var leftPressLocation: CGPoint?
    var leftReleaseLocation: CGPoint?
    var nativeResizeStart: NativeResizeStart?
    var nativeResizeCorrectionsByWindowId: [Int: NativeResizeCorrection] = [:]
    var nativeCrossDisplayMove: NativeCrossDisplayMove?

    var lastFocusFollowsMouseTime: Date = .distantPast
    var latestFocusFollowsMouseSample: FocusFollowsMouseSample?
    let focusFollowsMouseDebounce: TimeInterval = 0.1
    var dragGhostController: DragGhostController?

    var gesturePhase: GesturePhase = .idle
    var gestureStartX: CGFloat = 0.0
    var gestureStartY: CGFloat = 0.0
    var gestureLastAverageX: CGFloat = 0.0
    var gestureLastAverageY: CGFloat = 0.0
    var gestureLastTimestamp: TimeInterval = 0
    var lockedGestureContext: LockedGestureContext?
    var activeGestureMode: TrackpadGestureMode?
    var gestureFingerCountMismatchSince: TimeInterval?
    var viewportGestureSessionID: AnimationDriver.GestureSessionID?
    var workspaceSwipeFired = false
    let workspaceSwipeTracker = SwipeTracker()
    var suppressGestureStartUntilAllTouchesLift = false
    var consumeTrackpadScrollUntilAllTouchesLift = false
    var suppressTrackpadMomentumScroll = false
    var contactSessions = MultitouchContactSessions()
    var consumedTrackpadSessions: [UInt64: MultitouchContactSession] = [:]
    var horizontalWheelTracker = NiriScrollTracker(tick: niriWheelScrollTickAmount)
    var verticalWheelTracker = NiriScrollTracker(tick: niriWheelScrollTickAmount)
}

struct LiveDragPointer {
    var location: CGPoint?
    var samples: [MouseInputState.LivePointerSample] = []
}

struct LiveDragSession {
    var tabPull: MouseInputState.LiveTabPull?
    var referenceOffset: CGFloat?
    var edgeScroll: MouseInputState.LiveEdgeScroll?
    var edgeZoneHold: MouseInputState.LiveEdgeZoneHold?
    var hoverTimer: Timer?
    var followUp: Timer?
    var tracedView: LiveStripTrace?
}

struct LiveStripTrace: Equatable {
    struct Lock: Equatable {
        let windowIds: [Int]?
        let side: LiveColumnMove.Side
    }

    struct Column: Equatable {
        let windowIds: [Int]
        let isHomeSpot: Bool
        let isDropSpace: Bool
        let minX: Int
        let maxX: Int
    }

    let label: String
    let workspaceId: WorkspaceDescriptor.ID
    let activeColumnIndex: Int
    let viewOffset: String
    let liveOffset: String?
    let lock: Lock?
    let columns: [Column]
    let phase: LiveColumnMove.Phase?

    var view: String {
        let lockText = lock.map { lock in
            "\(lock.windowIds.map(Self.ids) ?? "?")/\(lock.side)"
        } ?? "none"
        let columnsText = columns.map { column in
            let ids = Self.ids(column.windowIds)
            let name = column.isHomeSpot ? "*\(ids)" : column.isDropSpace ? "_" : ids
            return "\(name)@\(column.minX)-\(column.maxX)"
        }
        return "ws=\(workspaceId) active=\(activeColumnIndex) "
            + "off=\(viewOffset) live=\(liveOffset ?? "-") "
            + "lock=\(lockText) cols=[\(columnsText.joined(separator: ","))] phase=\(phase.map { "\($0)" } ?? "-")"
    }

    private static func ids(_ windowIds: [Int]) -> String {
        windowIds.map(String.init).joined(separator: "+")
    }
}
