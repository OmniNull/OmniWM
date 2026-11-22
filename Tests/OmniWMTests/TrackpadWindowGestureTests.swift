// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class TrackpadWindowGestureTests: XCTestCase {
    private let workingFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)

    @MainActor
    private struct GestureDriver {
        let handler: MouseEventHandler
        let location: CGPoint
        var contactSession: MultitouchContactSession?
        var time: TimeInterval = 100

        mutating func begin(fingers: Int, x: CGFloat, y: CGFloat = 0.5) {
            send(.began, fingers: fingers, x: x, y: y)
        }

        mutating func frame(fingers: Int, x: CGFloat, y: CGFloat = 0.5, after dt: TimeInterval = 0.01) {
            time += dt
            send(.changed, fingers: fingers, x: x, y: y)
        }

        mutating func drag(fingers: Int, fromX: CGFloat, toX: CGFloat, steps: Int = 10, y: CGFloat = 0.5) {
            for step in 1 ... steps {
                frame(fingers: fingers, x: fromX + (toX - fromX) * CGFloat(step) / CGFloat(steps), y: y)
            }
        }

        mutating func end(_ phase: NSEvent.Phase = .ended) {
            time += 0.01
            send(phase, fingers: 0, x: 0, y: 0)
        }

        private func send(_ phase: NSEvent.Phase, fingers: Int, x: CGFloat, y: CGFloat) {
            let touches = (0 ..< fingers).map { _ in
                MouseEventHandler.GestureTouchSample(phase: .moved, normalizedPosition: CGPoint(x: x, y: y))
            }
            handler.receiveTapGestureEvent(
                MouseEventHandler.GestureEventSnapshot(
                    location: location,
                    phaseRawValue: phase.rawValue,
                    timestamp: time,
                    touches: phase == .ended || phase == .cancelled ? [] : touches,
                    contactSession: contactSession
                )
            )
        }
    }

    @MainActor
    private struct NiriFixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let monitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID
        let first: NiriWindow
        let second: NiriWindow
        let firstFrame: CGRect
        let secondFrame: CGRect

        var handler: MouseEventHandler {
            controller.mouseEventHandler
        }

        var travelToSecond: CGFloat {
            (secondFrame.midX - firstFrame.midX) /
                (monitor.frame.width * CGFloat(SettingsExport.Gestures.defaultMoveSensitivity))
        }

        var firstRightEdgeGrip: CGPoint {
            CGPoint(x: firstFrame.maxX - 20, y: firstFrame.midY)
        }

        func windowOrder() -> [WindowToken] {
            engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) }
        }

        func frames() -> [WindowToken: CGRect] {
            let gap = controller.innerGap(for: monitor)
            return engine.calculateLayout(
                state: controller.workspaceManager.niriViewportState(for: workspaceId),
                workspaceId: workspaceId,
                monitorFrame: controller.insetWorkingFrame(for: monitor),
                gaps: (horizontal: gap, vertical: gap),
                orientation: .horizontal
            )
        }

        func driver(at location: CGPoint) -> GestureDriver {
            GestureDriver(handler: handler, location: location)
        }
    }

    @MainActor
    private struct DwindleFixture {
        let controller: WMController
        let engine: DwindleLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let screen: CGRect
        let first: WindowToken
        let second: WindowToken
        let firstFrame: CGRect
        let secondFrame: CGRect

        var handler: MouseEventHandler {
            controller.mouseEventHandler
        }

        func presentedFrame(_ token: WindowToken) -> CGRect? {
            engine.presentedFrame(for: token, in: workspaceId, at: 0)
        }

        func relayout() {
            _ = engine.calculateLayout(for: workspaceId, screen: screen)
            engine.cancelAnimations(in: workspaceId)
        }

        func driver(at location: CGPoint) -> GestureDriver {
            GestureDriver(handler: handler, location: location)
        }
    }

    func testFourFingerDragOpensALiveLandingBeforeRelease() throws {
        let fixture = try makeNiriFixture(pid: 9_101)
        let handler = fixture.handler
        XCTAssertEqual(fixture.windowOrder(), [fixture.first.token, fixture.second.token])

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        XCTAssertEqual(handler.tapInputs.gesturePhase, .armed)
        XCTAssertFalse(handler.state.isMoving)

        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.2 + fixture.travelToSecond)

        XCTAssertEqual(handler.tapInputs.gesturePhase, .committed)
        XCTAssertEqual(handler.state.activeGestureMode, .windowMove)
        XCTAssertTrue(handler.state.isMoving)
        XCTAssertTrue(handler.state.gestureOwnsWindowInteraction)
        XCTAssertEqual(handler.state.activeInteractionSource, .trackpadGesture)
        XCTAssertEqual(handler.state.moveLayout, .niri)
        XCTAssertNil(handler.state.activeInteractionButton)
        XCTAssertEqual(fixture.engine.liveColumnMove?.windowToken, fixture.first.token)
        XCTAssertFalse(handler.isViewportGestureActive)
        XCTAssertTrue(handler.isInteractiveGestureActive)
        let held = try XCTUnwrap(fixture.engine.liveColumnMove)
        XCTAssertNotNil(held.narrowedSlot)
        XCTAssertEqual(held.floatingFrame?.center.x, fixture.secondFrame.midX)
        XCTAssertNil(handler.state.nativeTitleBarDrag)

        gesture.end()

        XCTAssertEqual(handler.tapInputs.gesturePhase, .idle)
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertFalse(handler.state.gestureOwnsWindowInteraction)
        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
    }

    func testThreeFingerResizePreservesLifecycleAcrossSensitivities() throws {
        let cases: [(move: Double, resize: Double)] = [(2, 1), (1, 1), (1, 0.5)]
        let start: CGFloat = 3 / 8
        let fingerTravel: CGFloat = 1 / 8
        for speeds in cases {
            let fixture = try makeNiriFixture(pid: 9_102)
            fixture.controller.settings.gestures.windowResizeSensitivity = speeds.resize
            fixture.controller.settings.gestures.windowMoveSensitivity = speeds.move
            let delta = fixture.monitor.frame.width * fingerTravel * CGFloat(speeds.resize)
            let handler = fixture.handler
            let widthBefore = fixture.firstFrame.width

            var gesture = fixture.driver(at: fixture.firstRightEdgeGrip)
            gesture.begin(fingers: 3, x: start)
            gesture.drag(fingers: 3, fromX: start, toX: start + fingerTravel, steps: 8)

            XCTAssertEqual(handler.state.activeGestureMode, .windowResize)
            XCTAssertTrue(handler.state.isResizing)
            XCTAssertTrue(handler.state.gestureOwnsWindowInteraction)
            XCTAssertEqual(handler.state.resizeLayout, .niri)
            XCTAssertNil(handler.state.activeInteractionButton)
            let resize = try XCTUnwrap(fixture.engine.interactiveResize)
            XCTAssertTrue(resize.edges.contains(.right))
            XCTAssertEqual(resize.startMouseLocation, gesture.location)
            let context = try XCTUnwrap(handler.state.lockedGestureContext)
            XCTAssertEqual(handler.gestureWindowLocation(for: context).x, gesture.location.x + delta)

            gesture.end()

            XCTAssertFalse(handler.state.isResizing)
            XCTAssertFalse(handler.state.gestureOwnsWindowInteraction)
            XCTAssertNil(fixture.engine.interactiveResize)
            XCTAssertEqual(handler.tapInputs.gesturePhase, .idle)
            let widthAfter = try XCTUnwrap(fixture.frames()[fixture.first.token]).width
            XCTAssertEqual(widthAfter, widthBefore + delta)
        }
    }

    func testWindowGestureWithNoWindowUnderCursorNeverArms() throws {
        let fixture = try makeNiriFixture(pid: 9_104)
        let handler = fixture.handler

        var gesture = fixture.driver(at: CGPoint(x: workingFrame.maxX + 400, y: workingFrame.midY))
        gesture.begin(fingers: 4, x: 0.2)
        XCTAssertEqual(handler.tapInputs.gesturePhase, .idle)
        XCTAssertTrue(
            handler.state.suppressGestureStartUntilAllTouchesLift,
            "The cursor cannot move while fingers rest, so retrying every frame is pointless"
        )
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.45, steps: 5)
        XCTAssertEqual(handler.tapInputs.gesturePhase, .idle)
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.liveColumnMove)
        gesture.end()
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)
    }

    func testDisabledWindowGesturesIgnoreTheirFingerCount() throws {
        let fixture = try makeNiriFixture(pid: 9_105)
        fixture.controller.settings.gestures.windowMoveEnabled = false
        fixture.controller.settings.gestures.windowResizeEnabled = false
        fixture.controller.settings.gestures.workspaceSwipeEnabled = true
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.45, steps: 5)
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.liveColumnMove)
        gesture.end()
    }

    func testAmbiguousWindowResizeAndColumnScrollDoesNotArm() throws {
        let fixture = try makeNiriFixture(pid: 9_106)
        fixture.controller.settings.gestures.scrollEnabled = true
        fixture.controller.settings.gestures.fingerCount = .three
        fixture.controller.settings.gestures.windowResizeFingerCount = .three
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstRightEdgeGrip)
        gesture.begin(fingers: 3, x: 0.4)
        gesture.drag(fingers: 3, fromX: 0.4, toX: 0.48, steps: 4)
        XCTAssertNil(handler.state.activeGestureMode)
        XCTAssertFalse(handler.state.isResizing)
        XCTAssertFalse(handler.isViewportGestureActive)
        gesture.end()
        XCTAssertFalse(handler.state.isResizing)
    }

    func testCancelledTouchSessionRevertsMoveInsteadOfDropping() throws {
        let fixture = try makeNiriFixture(pid: 9_107)
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.2 + fixture.travelToSecond)
        XCTAssertTrue(handler.state.isMoving)

        gesture.end(.cancelled)

        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(handler.tapInputs.gesturePhase, .idle)
        XCTAssertEqual(fixture.windowOrder(), [fixture.first.token, fixture.second.token])
    }

    func testLiftingOneFingerDropsTheWindowAfterTheFlickerGrace() throws {
        let fixture = try makeNiriFixture(pid: 9_108)
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        let endX = 0.2 + fixture.travelToSecond
        gesture.drag(fingers: 4, fromX: 0.2, toX: endX)
        XCTAssertTrue(handler.state.isMoving)

        for _ in 0 ..< 5 {
            gesture.frame(fingers: 3, x: endX, after: 0.02)
        }
        XCTAssertTrue(handler.state.isMoving, "100ms of three fingers is flicker, not a release")
        gesture.frame(fingers: 3, x: endX, after: 0.1)

        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
        XCTAssertTrue(handler.state.suppressGestureStartUntilAllTouchesLift)

        gesture.end()
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)
    }

    func testBriefFingerCountDipDoesNotEndResize() throws {
        let fixture = try makeNiriFixture(pid: 9_113)
        let handler = fixture.handler
        let widthBefore = fixture.firstFrame.width

        var gesture = fixture.driver(at: fixture.firstRightEdgeGrip)
        gesture.begin(fingers: 3, x: 0.4)
        gesture.drag(fingers: 3, fromX: 0.4, toX: 0.45, steps: 4)
        XCTAssertTrue(handler.state.isResizing)

        gesture.frame(fingers: 2, x: 0.46)
        gesture.frame(fingers: 2, x: 0.47)
        XCTAssertTrue(handler.state.isResizing, "a two-frame dip must not end the resize")
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)

        gesture.drag(fingers: 3, fromX: 0.45, toX: 0.5, steps: 4)
        XCTAssertTrue(handler.state.isResizing)
        gesture.end()

        let widthAfter = try XCTUnwrap(fixture.frames()[fixture.first.token]).width
        XCTAssertEqual(widthAfter, widthBefore + 160, "the full travel must land despite the dip")
    }

    func testTransientExtraFingerDoesNotAbortMove() throws {
        let fixture = try makeNiriFixture(pid: 9_114)
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.28, steps: 4)
        XCTAssertTrue(handler.state.isMoving)

        gesture.frame(fingers: 5, x: 0.29)
        XCTAssertTrue(handler.state.isMoving, "a resting palm for one frame must not cancel the move")
        gesture.frame(fingers: 4, x: 0.3)
        XCTAssertTrue(handler.state.isMoving)

        gesture.end()
        XCTAssertFalse(handler.state.isMoving)
    }

    func testLateFourthFingerReArmsFromResizeToMoveBeforeCommit() throws {
        let fixture = try makeNiriFixture(pid: 9_112)
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 3, x: 0.2)
        gesture.frame(fingers: 3, x: 0.21)
        XCTAssertEqual(handler.tapInputs.gesturePhase, .armed)
        XCTAssertEqual(handler.state.lockedGestureContext?.fingerCount, 3)

        gesture.frame(fingers: 4, x: 0.21)
        gesture.drag(fingers: 4, fromX: 0.21, toX: 0.21 + fixture.travelToSecond)
        XCTAssertEqual(handler.state.lockedGestureContext?.fingerCount, 4)
        XCTAssertEqual(handler.state.activeGestureMode, .windowMove)
        XCTAssertTrue(handler.state.isMoving)
        XCTAssertFalse(handler.state.isResizing)

        gesture.end()
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
    }

    func testMouseEventsDoNotDisturbGestureOwnedMove() throws {
        let fixture = try makeNiriFixture(pid: 9_109)
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.28, steps: 4)
        XCTAssertTrue(handler.state.isMoving)

        let before = try XCTUnwrap(fixture.engine.liveColumnMove?.floatingFrame)
        let pointer = handler.livePointer.location
        XCTAssertFalse(handler.receiveTapMouseDown(at: fixture.secondFrame.center, modifiers: []))
        handler.pressedMouseButtonsProvider = { 0 }
        handler.dispatchMouseDragged(at: fixture.secondFrame.center)
        XCTAssertTrue(handler.state.isMoving, "A mouse drag without a held button must not cancel a gesture move")
        handler.dispatchMouseUp(at: fixture.secondFrame.center)
        XCTAssertTrue(handler.state.isMoving, "A stray mouse-up must not drop a gesture move")
        XCTAssertFalse(
            handler.dispatchMouseDown(at: fixture.secondFrame.center, modifiers: .maskAlternate),
            "A modifier click cannot start a second interaction while the gesture owns one"
        )
        XCTAssertEqual(fixture.engine.liveColumnMove?.floatingFrame, before)
        XCTAssertEqual(handler.livePointer.location, pointer)

        gesture.end()
        XCTAssertFalse(handler.state.isMoving)
    }

    func testDisablingControllerMidGestureCancelsMoveAndClearsGestureState() throws {
        let fixture = try makeNiriFixture(pid: 9_110)
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.28, steps: 4)
        XCTAssertTrue(handler.state.isMoving)

        fixture.controller.isEnabled = false
        gesture.frame(fingers: 4, x: 0.3)

        XCTAssertFalse(handler.state.isMoving)
        XCTAssertFalse(handler.state.gestureOwnsWindowInteraction)
        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(handler.tapInputs.gesturePhase, .idle)
        XCTAssertEqual(fixture.windowOrder(), [fixture.first.token, fixture.second.token])

        gesture.end()
        fixture.controller.isEnabled = true
    }

    func testCleanupWhileGestureOwnsMoveReconcilesEverything() throws {
        let fixture = try makeNiriFixture(pid: 9_111)
        let handler = fixture.handler

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.28, steps: 4)
        XCTAssertTrue(handler.state.isMoving)

        handler.cleanup()

        XCTAssertFalse(handler.state.isMoving)
        XCTAssertFalse(handler.state.gestureOwnsWindowInteraction)
        XCTAssertNil(fixture.engine.liveColumnMove)
        XCTAssertEqual(handler.tapInputs.gesturePhase, .idle)
        XCTAssertFalse(handler.isInteractiveGestureActive)
    }

    func testFourFingerDragSwapsDwindleTilesBeforeLiftAndSettlesAfterFingerGrace() throws {
        let fixture = try makeDwindleFixture(pid: 9_201)
        let handler = fixture.handler
        let travel = (fixture.secondFrame.midX - fixture.firstFrame.midX)
            / (workingFrame.width * CGFloat(SettingsExport.Gestures.defaultMoveSensitivity))
        let fingers = fixture.controller.settings.gestures.windowMoveFingerCount.rawValue
        let startX: CGFloat = 1 / 4
        let endX = startX + travel

        let grace = TrackpadGestureMode.windowMove.fingerCountGrace
        var activeCount = 0
        func emit(fingers: Int, x: CGFloat, at time: TimeInterval) throws {
            let contact = MultitouchGestureSource.RawTouch(x: Float(x), y: 0.5)
            let delivery = MultitouchGestureSource.makeSnapshot(
                frame: .init(touches: Array(repeating: contact, count: fingers), timestamp: time),
                location: fixture.firstFrame.center, previousActiveCount: activeCount
            )
            activeCount = delivery.activeCount
            handler.receiveTapGestureEvent(try XCTUnwrap(delivery.snapshot))
        }
        try emit(fingers: fingers, x: startX, at: 0)
        try emit(fingers: fingers, x: endX, at: grace / 2)
        XCTAssertTrue(handler.state.isMoving)
        XCTAssertEqual(handler.state.moveLayout, .dwindle)
        XCTAssertEqual(fixture.engine.liveMoveToken, fixture.first)
        XCTAssertTrue(fixture.engine.liveMoveHoldsTarget(at: fixture.secondFrame.center))
        fixture.relayout()
        XCTAssertEqual(fixture.presentedFrame(fixture.first), fixture.secondFrame)
        XCTAssertEqual(fixture.presentedFrame(fixture.second), fixture.firstFrame)

        let mismatch = grace
        try emit(fingers: fingers - 1, x: endX, at: mismatch)
        try emit(fingers: fingers - 1, x: endX, at: mismatch + grace / 2)
        XCTAssertTrue(handler.state.isMoving)
        try emit(fingers: fingers - 1, x: endX, at: (mismatch + grace).nextUp)
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertNil(fixture.engine.liveMoveToken)
        fixture.relayout()
        XCTAssertEqual(fixture.presentedFrame(fixture.first), fixture.secondFrame)
        XCTAssertEqual(fixture.presentedFrame(fixture.second), fixture.firstFrame)
        try emit(fingers: 0, x: endX, at: mismatch + grace * 2)
    }

    func testThreeFingerDragResizesDwindleSplit() throws {
        let fixture = try makeDwindleFixture(pid: 9_202)
        let handler = fixture.handler

        var gesture = fixture.driver(at: CGPoint(x: fixture.firstFrame.maxX - 20, y: fixture.firstFrame.midY))
        gesture.begin(fingers: 3, x: 0.4)
        gesture.drag(fingers: 3, fromX: 0.4, toX: 0.5, steps: 8)
        XCTAssertTrue(handler.state.isResizing)
        XCTAssertEqual(handler.state.resizeLayout, .dwindle)
        XCTAssertEqual(fixture.engine.interactiveResize?.token, fixture.first)

        gesture.end()

        XCTAssertFalse(handler.state.isResizing)
        XCTAssertNil(fixture.engine.interactiveResize)
        fixture.relayout()
        let widthAfter = try XCTUnwrap(fixture.presentedFrame(fixture.first)).width
        XCTAssertGreaterThan(widthAfter, fixture.firstFrame.width + 100)
    }

    func testDwindleResizeGestureFallsBackToTheEdgeThatCanMove() throws {
        let fixture = try makeDwindleFixture(pid: 9_203)
        let handler = fixture.handler

        var gesture = fixture.driver(at: CGPoint(x: fixture.firstFrame.minX + 20, y: fixture.firstFrame.minY + 20))
        gesture.begin(fingers: 3, x: 0.4)
        gesture.drag(fingers: 3, fromX: 0.4, toX: 0.5, steps: 8)
        XCTAssertTrue(handler.state.isResizing)
        XCTAssertEqual(fixture.engine.interactiveResize?.edges, .right)
        XCTAssertEqual(handler.state.currentHoveredEdges, .right)
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)

        gesture.end()

        XCTAssertFalse(handler.state.isResizing)
        fixture.relayout()
        let widthAfter = try XCTUnwrap(fixture.presentedFrame(fixture.first)).width
        XCTAssertGreaterThan(widthAfter, fixture.firstFrame.width + 100)
    }

    func testModifiedRightDragDoesNotStartDwindleResizeAtEitherEdge() throws {
        let fixture = try makeDwindleFixture(pid: 9_204)
        for x in [
            fixture.firstFrame.minX + FrameTolerance.frameWrite,
            fixture.firstFrame.maxX - FrameTolerance.frameWrite
        ] {
            let point = CGPoint(x: x, y: fixture.firstFrame.midY)
            XCTAssertFalse(fixture.handler.dispatchMouseDown(at: point, modifiers: .maskAlternate, button: .right))
            fixture.handler.dispatchMouseDragged(
                at: CGPoint(x: x + fixture.firstFrame.width / 8, y: point.y), button: .right
            )
            XCTAssertNil(fixture.engine.interactiveResize)
            XCTAssertFalse(fixture.handler.state.isResizing)
            XCTAssertNil(fixture.handler.tapInputs.capturedInteractionButton)
            fixture.handler.dispatchMouseUp(at: point, button: .right)
        }
    }

    func testRearmingPreservesContactConsumptionUntilFreshContact() throws {
        let fixture = try makeNiriFixture(pid: 9_115)
        let handler = fixture.handler
        let contact = MultitouchContactSession(generation: 1, slot: 0, session: 1, senderId: 0x677)
        var contacts = MultitouchContactSessions()
        contacts.generation = 1
        contacts.sessions[0] = 1
        handler.updateContactSessions(contacts)
        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.contactSession = contact
        gesture.begin(fingers: 3, x: 0.2)
        gesture.frame(fingers: 4, x: 0.21)
        XCTAssertEqual(handler.state.lockedGestureContext?.contactSession, contact)
        gesture.drag(fingers: 4, fromX: 0.21, toX: 0.21 + fixture.travelToSecond)
        gesture.end()
        XCTAssertTrue(handler.consumesTrackpadSession(senderId: 0x677))
        XCTAssertFalse(handler.consumesTrackpadSession(senderId: 0x999))
        contacts.sessions[0] = 2
        handler.updateContactSessions(contacts)
        XCTAssertFalse(handler.consumesTrackpadSession(senderId: 0x677))
    }

    func testArmedOverviewCannotRearmIntoWindowMoveBeforeLift() throws {
        let fixture = try makeNiriFixture(pid: 9_116)
        let handler = fixture.handler
        fixture.controller.settings.gestures.windowResizeEnabled = false
        fixture.controller.settings.gestures.overviewGestureEnabled = true
        fixture.controller.settings.gestures.overviewGestureFingerCount = .three
        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 3, x: 0.2)
        XCTAssertEqual(handler.state.lockedGestureContext?.overviewAction, .open)
        gesture.frame(fingers: 4, x: 0.21)
        gesture.frame(fingers: 4, x: 0.5)
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertTrue(handler.state.suppressGestureStartUntilAllTouchesLift)
        gesture.end()
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.2 + fixture.travelToSecond)
        XCTAssertTrue(handler.state.isMoving)
        gesture.end()
    }

    func testSourceReplacementClearsMoveAndResizeAndAllowsNewGesture() throws {
        for fingers in [3, 4] {
            let fixture = try makeNiriFixture(pid: 9_117)
            let handler = fixture.handler
            var gesture = fixture.driver(at: fixture.firstRightEdgeGrip)
            gesture.begin(fingers: fingers, x: 0.2)
            gesture.drag(fingers: fingers, fromX: 0.2, toX: 0.35)
            XCTAssertTrue(handler.state.gestureOwnsWindowInteraction)
            handler.resetForMultitouchSourceReplacement()
            XCTAssertNil(fixture.engine.liveColumnMove)
            XCTAssertNil(fixture.engine.interactiveResize)
            XCTAssertNil(handler.state.activeInteractionSource)
            XCTAssertEqual(handler.tapInputs.gesturePhase, .idle)
            XCTAssertFalse(handler.state.isMoving)
            XCTAssertFalse(handler.state.isResizing)
            gesture.begin(fingers: fingers, x: 0.2)
            gesture.drag(fingers: fingers, fromX: 0.2, toX: 0.35)
            XCTAssertTrue(handler.state.gestureOwnsWindowInteraction)
            gesture.end()
        }
    }

    func testFullLiftDuringFingerGraceDropsImmediately() throws {
        let fixture = try makeNiriFixture(pid: 9_118)
        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.2 + fixture.travelToSecond)
        gesture.frame(fingers: 3, x: 0.3)
        XCTAssertTrue(fixture.handler.state.isMoving)
        gesture.end()
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
        XCTAssertNil(fixture.handler.state.gestureFingerCountMismatchSince)
        XCTAssertFalse(fixture.handler.state.isMoving)
    }

    func testCancelledResizeKeepsAppliedDimensions() throws {
        let fixture = try makeNiriFixture(pid: 9_119)
        var gesture = fixture.driver(at: fixture.firstRightEdgeGrip)
        gesture.begin(fingers: 3, x: 0.4)
        gesture.drag(fingers: 3, fromX: 0.4, toX: 0.5)
        let during = try XCTUnwrap(fixture.frames()[fixture.first.token]).width
        XCTAssertGreaterThan(during, fixture.firstFrame.width)
        gesture.end(.cancelled)
        XCTAssertEqual(try XCTUnwrap(fixture.frames()[fixture.first.token]).width, during)
        XCTAssertNil(fixture.engine.interactiveResize)
        XCTAssertNil(fixture.handler.state.activeInteractionSource)
    }

    func testRestingFingerBelowTheGestureFloorStillEndsAMoveAfterTheFlickerGrace() async throws {
        let fixture = try makeNiriFixture(pid: 9_121)
        let handler = fixture.handler
        let backend = FakeMultitouchBackend()
        backend.enumerations = [FakeMultitouchBackend.enumeration([
            FakeMultitouchBackend.device(pointer: 0xA1, registryId: 101)
        ])]
        let sleeper = ManualMultitouchSleeper()
        let source = MultitouchGestureSource(
            operations: backend.operations(sleeper: sleeper),
            topologyMonitoringEnabled: false
        )
        defer {
            fixture.controller.layoutRefreshController.resetState()
            handler.cleanup()
            await sleeper.resumeAll()
        }
        XCTAssertTrue(handler.installMultitouchSource(source))
        try await sleeper.waitForScheduledSleep(of: source)
        try await sleeper.resumeNext()
        try await sleeper.waitForScheduledSleep(of: source)

        let location = fixture.firstFrame.center
        let startX: Float = 0.2
        let endX = startX + Float(fixture.travelToSecond)
        var time = 100.0
        func emit(fingers: Int, x: Float, after interval: TimeInterval = 0.01) {
            time += interval
            handler.liveDragClock = { [time] in time }
            backend.emitFrame(
                registryId: 101,
                touches: Array(repeating: (x: x, y: Float(0.5)), count: fingers),
                timestamp: time
            )
            source.drainRawFrameMailbox(location: location)
        }

        emit(fingers: 4, x: startX)
        for step in 1 ... 10 {
            emit(fingers: 4, x: startX + (endX - startX) * Float(step) / 10)
        }
        XCTAssertTrue(handler.state.isMoving)
        let move = try XCTUnwrap(fixture.engine.liveColumnMove)
        let slot = move.dropSpaceId ?? move.homeColumnId
        let shownOrder = fixture.engine.columns(in: fixture.workspaceId).compactMap { column in
            column.id == slot ? fixture.first.token : column.windowNodes.first { $0 === fixture.second }?.token
        }

        let grace = TrackpadGestureMode.windowMove.fingerCountGrace
        emit(fingers: 1, x: endX)
        emit(fingers: 1, x: endX, after: grace / 2)
        XCTAssertTrue(handler.state.isMoving)
        emit(fingers: 1, x: endX, after: grace)
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertEqual(fixture.windowOrder(), shownOrder)

        emit(fingers: 0, x: 0)
    }

    func testMoveOvershootKeepsTheLivePointAtTheStartingDisplaysEdge() throws {
        let fixture = try makeNiriFixture(pid: 9_120)
        let controller = fixture.controller
        controller.settings.gaps.size = 0
        controller.workspaceManager.setGaps(to: 0)
        controller.settings.gaps.outerGapLeft = 0
        controller.settings.gaps.outerGapRight = 0
        controller.settings.gaps.outerGapTop = 0
        controller.settings.gaps.outerGapBottom = 0
        controller.settings.borders.enabled = false
        controller.workspaceManager.applySettings()
        let frame = fixture.monitor.frame
        let width = frame.width / 2
        for column in fixture.engine.columns(in: fixture.workspaceId) {
            column.width = .fixed(width)
            column.cachedWidth = width
        }
        controller.workspaceManager.withNiriViewportState(for: fixture.workspaceId) { state in
            state.activeColumnIndex = 0
            state.selectedNodeId = fixture.first.id
            state.viewOffset = 0
        }
        let first = CGRect(x: frame.minX, y: frame.minY, width: width, height: frame.height)
        let second = first.offsetBy(dx: width, dy: 0)
        XCTAssertEqual(controller.innerGap(for: fixture.monitor), 0)
        XCTAssertEqual(controller.insetWorkingFrame(for: fixture.monitor), frame)
        XCTAssertEqual(fixture.frames(), [fixture.first.token: first, fixture.second.token: second])
        controller.settings.gestures.windowMoveSensitivity = GestureSettings.windowGestureSensitivityRange.upperBound
        var gesture = fixture.driver(at: first.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 1)
        XCTAssertEqual(fixture.handler.liveDragSession?.edgeScroll?.edge, .trailing)
        XCTAssertEqual(fixture.engine.liveColumnMove?.workspaceId, fixture.workspaceId)
        let context = try XCTUnwrap(fixture.handler.state.lockedGestureContext)
        let point = fixture.handler.gestureWindowLocation(for: context)
        XCTAssertEqual(point, CGPoint(x: frame.maxX - 1, y: first.midY))
        XCTAssertTrue(second.contains(point))
        XCTAssertEqual(fixture.handler.livePointer.location, point)
        gesture.end()
        XCTAssertFalse(fixture.handler.state.isMoving)
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
    }

    private func makeController() -> WMController {
        let controller = WindowAdmissionTestSupport.controller(prefix: "TrackpadWindowGestureTests")
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        let settings = controller.settings
        settings.animationsEnabled = false
        settings.gestures.scrollEnabled = false
        settings.gestures.workspaceSwipeEnabled = false
        settings.gestures.windowMoveEnabled = true
        settings.gestures.windowMoveFingerCount = .four
        settings.gestures.windowResizeEnabled = true
        settings.gestures.windowResizeFingerCount = .three
        return controller
    }

    private func makeMonitor() -> Monitor {
        Monitor(
            id: .init(displayId: 52_001),
            displayId: 52_001,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Trackpad Window Gesture"
        )
    }

    private func makeNiriFixture(pid: pid_t) throws -> NiriFixture {
        let controller = makeController()
        let monitor = makeMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)

        var windows: [NiriWindow] = []
        for windowId in 1 ... 2 {
            let token = WindowToken(pid: pid, windowId: windowId)
            _ = controller.workspaceManager.addWindow(
                WindowAdmissionTestSupport.axRef(for: token),
                pid: pid,
                windowId: windowId,
                to: workspaceId
            )
            windows.append(engine.addWindow(token: token, to: workspaceId, afterSelection: windows.last?.id))
        }
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                windows[0].token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        for column in engine.columns(in: workspaceId) {
            column.cachedWidth = 700
        }
        let partial = NiriFixture(
            controller: controller,
            engine: engine,
            monitor: monitor,
            workspaceId: workspaceId,
            first: windows[0],
            second: windows[1],
            firstFrame: .zero,
            secondFrame: .zero
        )
        let frames = partial.frames()
        let firstFrame = try XCTUnwrap(frames[windows[0].token])
        let secondFrame = try XCTUnwrap(frames[windows[1].token])
        XCTAssertLessThan(firstFrame.maxX, secondFrame.minX)
        XCTAssertNotNil(engine.hitTestTiled(point: firstFrame.center, in: workspaceId))
        XCTAssertNotNil(engine.hitTestTiled(point: secondFrame.center, in: workspaceId))

        return NiriFixture(
            controller: controller,
            engine: engine,
            monitor: monitor,
            workspaceId: workspaceId,
            first: windows[0],
            second: windows[1],
            firstFrame: firstFrame,
            secondFrame: secondFrame
        )
    }

    private func makeDwindleFixture(pid: pid_t) throws -> DwindleFixture {
        let controller = makeController()
        let monitor = makeMonitor()
        controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .dwindle
            )
        ]
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.enableDwindleLayout()
        let engine = try XCTUnwrap(controller.dwindleEngine)
        controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
            controller.dwindleLayoutHandler.applyResolvedSettings(
                controller.resolvedDwindleSettings(for: monitor), to: engine
            )
        }
        var tokens: [WindowToken] = []
        for windowId in 1 ... 2 {
            let token = controller.workspaceManager.addWindow(
                WindowAdmissionTestSupport.axRef(for: WindowToken(pid: pid, windowId: windowId)),
                pid: pid,
                windowId: windowId,
                to: workspaceId
            )
            controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
                _ = engine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            }
            tokens.append(token)
        }
        let screen = controller.insetWorkingFrame(for: monitor)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)
        engine.cancelAnimations(in: workspaceId)
        let firstFrame = try XCTUnwrap(engine.presentedFrame(for: tokens[0], in: workspaceId, at: 0))
        let secondFrame = try XCTUnwrap(engine.presentedFrame(for: tokens[1], in: workspaceId, at: 0))
        XCTAssertNotEqual(firstFrame, secondFrame)
        XCTAssertEqual(controller.settings.workspaces.layoutType(for: "1"), .dwindle)

        return DwindleFixture(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            screen: screen,
            first: tokens[0],
            second: tokens[1],
            firstFrame: firstFrame,
            secondFrame: secondFrame
        )
    }
}
