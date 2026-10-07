// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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
            (secondFrame.center.x - firstFrame.center.x) / monitor.frame.width
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

    func testFourFingerDragMovesWindowAndSwapsOnRelease() throws {
        let fixture = try makeNiriFixture(pid: 9_101)
        let handler = fixture.handler
        XCTAssertEqual(fixture.windowOrder(), [fixture.first.token, fixture.second.token])

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        XCTAssertEqual(handler.state.gesturePhase, .armed)
        XCTAssertFalse(handler.state.isMoving)

        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.2 + fixture.travelToSecond)

        XCTAssertEqual(handler.state.gesturePhase, .committed)
        XCTAssertEqual(handler.state.activeGestureMode, .windowMove)
        XCTAssertTrue(handler.state.isMoving)
        XCTAssertTrue(handler.state.gestureOwnsWindowInteraction)
        XCTAssertEqual(handler.state.activeInteractionSource, .trackpadGesture)
        XCTAssertEqual(handler.state.moveLayout, .niri)
        XCTAssertNil(handler.state.activeInteractionButton)
        XCTAssertEqual(fixture.engine.interactiveMove?.windowToken, fixture.first.token)
        XCTAssertFalse(handler.isViewportGestureActive)
        XCTAssertTrue(handler.isInteractiveGestureActive)
        guard case let .window(_, targetToken, insertPosition)? = fixture.engine.interactiveMove?.currentHoverTarget
        else {
            return XCTFail("Expected the virtual cursor to hover the second window")
        }
        XCTAssertEqual(targetToken, fixture.second.token)
        XCTAssertEqual(insertPosition, .swap)

        gesture.end()

        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertFalse(handler.state.gestureOwnsWindowInteraction)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])
    }

    func testThreeFingerDragResizesWindowUntilFingersLift() throws {
        let fixture = try makeNiriFixture(pid: 9_102)
        let handler = fixture.handler
        let widthBefore = fixture.firstFrame.width

        var gesture = fixture.driver(at: fixture.firstRightEdgeGrip)
        gesture.begin(fingers: 3, x: 0.4)
        gesture.drag(fingers: 3, fromX: 0.4, toX: 0.5, steps: 8)

        XCTAssertEqual(handler.state.activeGestureMode, .windowResize)
        XCTAssertTrue(handler.state.isResizing)
        XCTAssertTrue(handler.state.gestureOwnsWindowInteraction)
        XCTAssertEqual(handler.state.resizeLayout, .niri)
        XCTAssertNil(handler.state.activeInteractionButton)
        let resize = try XCTUnwrap(fixture.engine.interactiveResize)
        XCTAssertTrue(resize.edges.contains(.right))
        XCTAssertEqual(resize.startMouseLocation, gesture.location)

        gesture.end()

        XCTAssertFalse(handler.state.isResizing)
        XCTAssertFalse(handler.state.gestureOwnsWindowInteraction)
        XCTAssertNil(fixture.engine.interactiveResize)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        let widthAfter = try XCTUnwrap(fixture.frames()[fixture.first.token]).width
        XCTAssertEqual(widthAfter, widthBefore + 160, accuracy: 2)
    }

    func testSensitivityScalesVirtualCursorTravel() throws {
        let fixture = try makeNiriFixture(pid: 9_103)
        fixture.controller.settings.gestures.windowGestureSensitivity = 0.5
        let widthBefore = fixture.firstFrame.width

        var gesture = fixture.driver(at: fixture.firstRightEdgeGrip)
        gesture.begin(fingers: 3, x: 0.4)
        gesture.drag(fingers: 3, fromX: 0.4, toX: 0.5, steps: 8)
        gesture.end()

        let widthAfter = try XCTUnwrap(fixture.frames()[fixture.first.token]).width
        XCTAssertEqual(widthAfter, widthBefore + 80, accuracy: 2)
    }

    func testWindowGestureWithNoWindowUnderCursorNeverArms() throws {
        let fixture = try makeNiriFixture(pid: 9_104)
        let handler = fixture.handler

        var gesture = fixture.driver(at: CGPoint(x: workingFrame.maxX + 400, y: workingFrame.midY))
        gesture.begin(fingers: 4, x: 0.2)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertTrue(
            handler.state.suppressGestureStartUntilAllTouchesLift,
            "The cursor cannot move while fingers rest, so retrying every frame is pointless"
        )
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.45, steps: 5)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
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
        XCTAssertNil(fixture.engine.interactiveMove)
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
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
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
        XCTAssertNil(fixture.engine.interactiveMove)
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
        XCTAssertEqual(widthAfter, widthBefore + 160, accuracy: 2, "the full travel must land despite the dip")
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
        XCTAssertEqual(handler.state.gesturePhase, .armed)
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

        handler.pressedMouseButtonsProvider = { 0 }
        handler.dispatchMouseDragged(at: fixture.secondFrame.center)
        XCTAssertTrue(handler.state.isMoving, "A mouse drag without a held button must not cancel a gesture move")
        handler.dispatchMouseUp(at: fixture.secondFrame.center)
        XCTAssertTrue(handler.state.isMoving, "A stray mouse-up must not drop a gesture move")
        XCTAssertFalse(
            handler.dispatchMouseDown(at: fixture.secondFrame.center, modifiers: .maskAlternate),
            "A modifier click cannot start a second interaction while the gesture owns one"
        )
        XCTAssertNotNil(fixture.engine.interactiveMove)

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
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
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
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(handler.isInteractiveGestureActive)
    }

    func testFourFingerDragSwapsDwindleTilesOnRelease() throws {
        let fixture = try makeDwindleFixture(pid: 9_201)
        let handler = fixture.handler
        let travel = (fixture.secondFrame.center.x - fixture.firstFrame.center.x) / fixture.screen.width

        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 0.2 + travel)

        XCTAssertTrue(handler.state.isMoving)
        XCTAssertEqual(handler.state.moveLayout, .dwindle)
        XCTAssertEqual(fixture.engine.interactiveMove?.token, fixture.first)
        XCTAssertEqual(fixture.engine.interactiveMove?.targetToken, fixture.second)

        gesture.end()

        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
        fixture.relayout()
        XCTAssertEqual(fixture.presentedFrame(fixture.first), fixture.secondFrame)
        XCTAssertEqual(fixture.presentedFrame(fixture.second), fixture.firstFrame)
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

    func testMouseResizeKeepsExactEdgesAndRefusesAnImmovableOne() throws {
        let fixture = try makeDwindleFixture(pid: 9_204)
        let leftGrip = CGPoint(x: fixture.firstFrame.minX + 20, y: fixture.firstFrame.midY)
        XCTAssertFalse(fixture.handler.dispatchMouseDown(at: leftGrip, modifiers: .maskAlternate, button: .right))
        XCTAssertNil(fixture.engine.interactiveResize)
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
            XCTAssertNil(fixture.engine.interactiveMove)
            XCTAssertNil(fixture.engine.interactiveResize)
            XCTAssertNil(handler.state.activeInteractionSource)
            XCTAssertEqual(handler.state.gesturePhase, .idle)
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
        XCTAssertTrue(handler.installMultitouchSource(source))
        await sleeper.waitForScheduledSleep(of: source)
        await sleeper.resumeNext()
        await sleeper.waitForScheduledSleep(of: source)

        let location = fixture.firstFrame.center
        let startX: Float = 0.2
        let endX = startX + Float(fixture.travelToSecond)
        var time = 100.0
        func emit(fingers: Int, x: Float) {
            time += 0.01
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

        for _ in 0 ..< 20 {
            emit(fingers: 1, x: endX)
        }
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertEqual(fixture.windowOrder(), [fixture.second.token, fixture.first.token])

        emit(fingers: 0, x: 0)
        fixture.controller.layoutRefreshController.resetState()
        handler.cleanup()
        await sleeper.resumeAll()
    }

    func testMoveOvershootKeepsEdgeWindowAsDropTarget() throws {
        let fixture = try makeNiriFixture(pid: 9_120)
        fixture.second.renderedFrame = CGRect(x: 800, y: 0, width: 800, height: 900)
        fixture.controller.settings.gestures.windowGestureSensitivity = 5
        var gesture = fixture.driver(at: fixture.firstFrame.center)
        gesture.begin(fingers: 4, x: 0.2)
        gesture.drag(fingers: 4, fromX: 0.2, toX: 1)
        guard case let .window(_, token, _)? = fixture.engine.interactiveMove?.currentHoverTarget else {
            return XCTFail("Overshoot lost the edge drop target")
        }
        XCTAssertEqual(token, fixture.second.token)
        gesture.end()
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
        settings.gestures.windowGestureSensitivity = 1.0
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
