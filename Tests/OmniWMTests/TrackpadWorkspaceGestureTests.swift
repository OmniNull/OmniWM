// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class TrackpadWorkspaceGestureTests: XCTestCase {
    func testOverviewSwipesOpenAndCloseOncePerContactWithoutSwitchingWorkspace() throws {
        for fingerCount in [OverviewGestureFingerCount.three, .four] {
            for invertDirection in [false, true] {
                let fixture = try makeFixture(workspaceSwipeEnabled: false)
                fixture.controller.setAnimationsEnabled(false)
                fixture.controller.settings.gestures.overviewGestureEnabled = true
                fixture.controller.settings.gestures.overviewGestureFingerCount = fingerCount
                fixture.controller.settings.gestures.invertDirection = invertDirection
                let fingers = fingerCount.rawValue
                defer {
                    if fixture.controller.isOverviewOpen() { fixture.controller.windowActionHandler.toggleOverview() }
                }
                sendFrame(fixture, phase: .began, fingers: fingers, x: 0.5, y: 0.2, at: 100)
                sendFrame(fixture, phase: .changed, fingers: fingers, x: 0.5, y: 0.6, at: 100.1)
                XCTAssertTrue(fixture.controller.isOverviewOpen())
                sendFrame(fixture, phase: .changed, fingers: fingers, x: 0.5, y: 0.1, at: 100.2)
                XCTAssertTrue(fixture.controller.isOverviewOpen())

                fixture.controller.windowActionHandler.toggleOverview()
                sendFrame(fixture, phase: .changed, fingers: fingers, x: 0.5, y: 0.2, at: 100.3)
                sendFrame(fixture, phase: .changed, fingers: fingers, x: 0.5, y: 0.6, at: 100.4)
                XCTAssertFalse(fixture.controller.isOverviewOpen(), "Opening again requires lifting all fingers")
                sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.5)

                sendFrame(fixture, phase: .began, fingers: fingers, x: 0.5, y: 0.8, at: 101)
                sendFrame(fixture, phase: .changed, fingers: fingers, x: 0.5, y: 0.4, at: 101.1)
                XCTAssertFalse(fixture.controller.isOverviewOpen(), "Downward swipes must not open Overview")
                sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 101.2)

                sendFrame(fixture, phase: .began, fingers: fingers, x: 0.5, y: 0.2, at: 102)
                sendFrame(fixture, phase: .changed, fingers: fingers, x: 0.5, y: 0.6, at: 102.1)
                XCTAssertTrue(fixture.controller.isOverviewOpen())
                sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 102.2)

                sendFrame(fixture, phase: .began, fingers: fingers, x: 0.5, y: 0.8, at: 103)
                sendFrame(fixture, phase: .changed, fingers: fingers, x: 0.5, y: 0.4, at: 103.1)
                XCTAssertFalse(fixture.controller.isOverviewOpen())
                sendFrame(fixture, phase: .changed, fingers: fingers - 1, x: 0.5, y: 0.4, at: 103.15)
                sendFrame(fixture, phase: .changed, fingers: fingers, x: 0.5, y: 0.9, at: 103.2)
                XCTAssertFalse(fixture.controller.isOverviewOpen(), "Closing consumes the contact until full lift")
                sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 103.3)
                _ = performVerticalSwipe(fixture, fingers: fingers, totalUnits: 40, startTime: 104)
                XCTAssertTrue(fixture.controller.isOverviewOpen())
                XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
            }
        }
    }

    func testKeyboardOpenedOverviewOnlyClosesForEnabledDownwardGesture() throws {
        let fixture = try makeFixture(enableNiri: false)
        let controller = fixture.controller
        controller.setAnimationsEnabled(false)
        controller.settings.gestures.overviewGestureEnabled = true
        controller.windowActionHandler.toggleOverview()
        defer { controller.windowActionHandler.dismissOverview() }

        let rejectedGestures: [(fingers: Int, x: CGFloat, y: CGFloat)] = [
            (fingers: 3, x: 0.5, y: 0.3),
            (fingers: 4, x: 0.5, y: 0.7),
            (fingers: 4, x: 0.7, y: 0.5),
            (fingers: 4, x: 0.75, y: 0.25),
            (fingers: 4, x: 0.5, y: 0.454)
        ]
        for (index, gesture) in rejectedGestures.enumerated() {
            let time = 100 + Double(index)
            sendFrame(fixture, phase: .began, fingers: gesture.fingers, x: 0.5, y: 0.5, at: time)
            sendFrame(
                fixture, phase: .changed, fingers: gesture.fingers,
                x: gesture.x, y: gesture.y, at: time + 0.1
            )
            sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time + 0.2)
            XCTAssertTrue(controller.isOverviewOpen())
            XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
        }

        controller.settings.gestures.overviewGestureEnabled = false
        _ = performVerticalSwipe(fixture, fingers: 4, from: 0.8, totalUnits: -40, startTime: 106)
        XCTAssertTrue(controller.isOverviewOpen())
        controller.settings.gestures.overviewGestureEnabled = true
        _ = performVerticalSwipe(fixture, fingers: 4, from: 0.8, totalUnits: -25, startTime: 107)
        XCTAssertFalse(controller.isOverviewOpen())
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
    }

    func testOverviewStateChangeInvalidatesArmedAndCommittedGestureUntilLift() throws {
        for initiallyOpen in [false, true] {
            for committed in [false, true] {
                let fixture = try makeFixture(workspaceSwipeEnabled: false)
                let controller = fixture.controller
                let handler = controller.mouseEventHandler
                controller.setAnimationsEnabled(false)
                controller.settings.gestures.overviewGestureEnabled = true
                if initiallyOpen { controller.windowActionHandler.toggleOverview() }
                defer { controller.windowActionHandler.dismissOverview() }
                let direction: CGFloat = initiallyOpen ? -1 : 1
                sendFrame(fixture, phase: .began, fingers: 4, x: 0.5, y: 0.5, at: 100)
                if committed {
                    sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.5 + direction * 0.04, at: 100.1)
                }
                XCTAssertEqual(handler.state.gesturePhase, committed ? .committed : .armed)

                controller.windowActionHandler.toggleOverview()
                sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.5 + direction * 0.2, at: 100.2)
                sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.5 - direction * 0.2, at: 100.3)
                XCTAssertEqual(controller.isOverviewOpen(), !initiallyOpen)
                XCTAssertTrue(handler.state.suppressGestureStartUntilAllTouchesLift)
                sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.4)
                _ = performVerticalSwipe(
                    fixture, fingers: 4, from: 0.5, totalUnits: -direction * 40, startTime: 101
                )
                XCTAssertEqual(controller.isOverviewOpen(), initiallyOpen)
            }
        }
    }

    func testOpeningOverviewStopsWorkspaceGestureUntilLift() throws {
        for committed in [false, true] {
            let fixture = try makeFixture()
            let controller = fixture.controller
            let handler = controller.mouseEventHandler
            controller.setAnimationsEnabled(false)
            controller.settings.gestures.overviewGestureEnabled = true
            defer { controller.windowActionHandler.dismissOverview() }
            sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: 100)
            if committed {
                sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.24, at: 100.1)
            }
            XCTAssertEqual(handler.state.gesturePhase, committed ? .committed : .armed)

            controller.windowActionHandler.toggleOverview()
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.6, at: 100.2)
            XCTAssertEqual(handler.state.gesturePhase, .idle)
            XCTAssertTrue(handler.state.suppressGestureStartUntilAllTouchesLift)
            XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
            controller.windowActionHandler.dismissOverview()
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.8, at: 100.3)
            XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
            sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.4)
            _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: 101)
            XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
        }
    }

    func testOverviewCloseOverOwnedSurfaceBlocksViewportGestureAndPreparesSelection() throws {
        let fixture = try makeFixture(scrollGestureEnabled: true)
        let controller = fixture.controller
        controller.setAnimationsEnabled(false)
        controller.settings.gestures.overviewGestureEnabled = true
        try addColumnGestureWindows(to: fixture)
        controller.windowActionHandler.toggleOverview()
        let surfaceId = "overview-gesture-close-test"
        let frame = fixture.monitor.frame
        controller.ownedWindowRegistry.registerWindowNumber(
            surfaceId: surfaceId,
            policy: SurfacePolicy(
                kind: .overview, hitTestPolicy: .interactive, capturePolicy: .included,
                suppressesManagedFocusRecovery: true
            ),
            windowNumber: 999_301,
            frameProvider: { frame },
            visibilityProvider: { true }
        )
        defer {
            controller.ownedWindowRegistry.unregister(surfaceId: surfaceId)
            controller.windowActionHandler.dismissOverview()
        }
        XCTAssertTrue(controller.isPointInOwnWindow(frame.center))
        let offset = controller.workspaceManager.niriViewportState(for: fixture.ws1).viewOffset
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.8, y: 0.5, at: 100)
        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.4, y: 0.5, at: 100.1)
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.2)
        XCTAssertTrue(controller.isOverviewOpen())
        XCTAssertEqual(controller.workspaceManager.niriViewportState(for: fixture.ws1).viewOffset, offset)
        _ = performVerticalSwipe(fixture, fingers: 4, from: 0.8, totalUnits: -40, startTime: 101)
        XCTAssertFalse(controller.isOverviewOpen())
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
        let viewport = controller.workspaceManager.niriViewportState(for: fixture.ws1)
        XCTAssertEqual(viewport.viewOffset, -controller.innerGap(for: fixture.monitor))
        XCTAssertFalse(viewport.hasPendingOffsetAnimation)
        XCTAssertFalse(controller.workspaceManager.animationDriver.hasMotion(in: fixture.ws1))
        XCTAssertFalse(controller.mouseEventHandler.isViewportGestureActive)
    }

    func testOverviewRecognizesShortPhysicalSwipe() throws {
        let fixture = try makeFixture(workspaceSwipeEnabled: false)
        fixture.controller.setAnimationsEnabled(false)
        fixture.controller.settings.gestures.overviewGestureEnabled = true
        defer { if fixture.controller.isOverviewOpen() { fixture.controller.windowActionHandler.toggleOverview() } }

        let points: [CGPoint] = [
            .init(x: 0.46528, y: 0.47502), .init(x: 0.46700, y: 0.48904),
            .init(x: 0.46936, y: 0.50272), .init(x: 0.47186, y: 0.51714),
            .init(x: 0.47439, y: 0.53116), .init(x: 0.47697, y: 0.54634),
            .init(x: 0.47967, y: 0.56112), .init(x: 0.48380, y: 0.58291),
            .init(x: 0.48759, y: 0.60068)
        ]
        for (index, point) in points.enumerated() {
            sendFrame(
                fixture,
                phase: index == 0 ? .began : .changed,
                fingers: 4,
                x: point.x,
                y: point.y,
                at: 100 + Double(index) * 0.008
            )
            if index < 4 { XCTAssertFalse(fixture.controller.isOverviewOpen()) }
        }
        XCTAssertTrue(fixture.controller.isOverviewOpen())
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
    }

    func testArmedOverviewFingerChangeCannotBecomeWorkspaceSwipeUntilLift() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.gestures.overviewGestureEnabled = true
        sendFrame(fixture, phase: .began, fingers: 4, x: 0.5, y: 0.2, at: 100)
        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.2, at: 100.1)
        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.3, at: 100.2)
        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.8, at: 100.3)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.4)
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: 101)
        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.8, at: 101.1)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
    }

    func testOverviewSwipeConsumesTailThenAllowsFreshScrolling() throws {
        for closing in [false, true] {
            let fixture = try makeFixture(workspaceSwipeEnabled: false)
            fixture.controller.setAnimationsEnabled(false)
            fixture.controller.settings.gestures.overviewGestureEnabled = true
            if closing { fixture.controller.windowActionHandler.toggleOverview() }
            let handler = fixture.controller.mouseEventHandler
            defer { fixture.controller.windowActionHandler.dismissOverview() }

            sendFrame(fixture, phase: .began, fingers: 4, x: 0.5, y: closing ? 0.8 : 0.2, at: 100)
            sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: closing ? 0.4 : 0.6, at: 100.1)

            XCTAssertEqual(fixture.controller.isOverviewOpen(), !closing)
            XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.changed.rawValue))
            XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 2, phase: 0))
            XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
            sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.2)
            XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)
            XCTAssertFalse(handler.state.consumeTrackpadScrollUntilAllTouchesLift)
            XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 2, phase: 0))
            XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
            sendFrame(fixture, phase: .began, fingers: 2, x: 0.5, y: 0.5, at: 101)
            XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
            XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.began.rawValue))
            XCTAssertFalse(handler.state.suppressTrackpadMomentumScroll)
        }
    }

    func testInteractiveOverviewSwipeTracksFromRecognitionCommit() throws {
        let fixture = try makeInteractiveOverviewFixture()
        let handler = fixture.controller.mouseEventHandler
        let actions = fixture.controller.windowActionHandler
        defer { dismissInteractiveOverview(fixture) }

        sendFrame(fixture, phase: .began, fingers: 4, x: 0.5, y: 0.2, at: 100)
        XCTAssertEqual(handler.state.gesturePhase, .armed)
        XCTAssertFalse(actions.isOverviewGestureActive)
        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.24, at: 100.1)
        XCTAssertEqual(handler.state.gesturePhase, .committed)
        guard case .opening = actions.overviewState
        else { return XCTFail("Expected the commit frame to begin tracking") }
        XCTAssertTrue(actions.isOverviewGestureActive)
        XCTAssertEqual(actions.overviewTransitionProgress, 0, accuracy: 0.000000000001)
        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.54, at: 100.2)
        XCTAssertEqual(actions.overviewTransitionProgress, 0.5, accuracy: 0.000000001)
        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.64, at: 100.3)
        XCTAssertEqual(actions.overviewTransitionProgress, 2.0 / 3.0, accuracy: 0.000000001)
        XCTAssertEqual(handler.state.gesturePhase, .committed)

        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.4)

        XCTAssertFalse(actions.isOverviewGestureActive)
        guard case .opening = actions.overviewState else { return XCTFail("Expected release above half to commit") }
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertTrue(handler.state.suppressTrackpadMomentumScroll)
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
    }

    func testInteractiveOverviewSwipeCancelsBelowHalf() throws {
        let fixture = try makeInteractiveOverviewFixture()
        let actions = fixture.controller.windowActionHandler
        defer { dismissInteractiveOverview(fixture) }

        sendFrame(fixture, phase: .began, fingers: 4, x: 0.5, y: 0.2, at: 100)
        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.24, at: 100.1)
        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.42, at: 100.2)
        XCTAssertEqual(actions.overviewTransitionProgress, 0.3, accuracy: 0.000000001)

        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.5)

        XCTAssertFalse(actions.isOverviewGestureActive)
        guard case .closing = actions.overviewState
        else { return XCTFail("Expected a slow release below half to cancel") }
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
    }

    func testInteractiveOverviewFlickCommitsFromLowProgress() throws {
        let fixture = try makeInteractiveOverviewFixture()
        let actions = fixture.controller.windowActionHandler
        defer { dismissInteractiveOverview(fixture) }

        sendFrame(fixture, phase: .began, fingers: 4, x: 0.5, y: 0.2, at: 100)
        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.24, at: 100.1)
        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.3, at: 100.12)
        XCTAssertEqual(actions.overviewTransitionProgress, 0.1, accuracy: 0.000000001)

        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.12)

        XCTAssertFalse(actions.isOverviewGestureActive)
        guard case .opening = actions.overviewState
        else { return XCTFail("Expected a flick to commit from low progress") }
    }

    func testSingleFrameOverviewFlickSurvivesCoalescedPartialLift() throws {
        let fixture = try makeInteractiveOverviewFixture()
        let actions = fixture.controller.windowActionHandler
        defer { dismissInteractiveOverview(fixture) }
        let mailbox = MultitouchFrameMailbox()
        mailbox.activate(generation: 1)
        for (fingers, y, timestamp): (Int, Float, Double) in [
            (4, 0.2, 100), (4, 0.24, 100.01), (4, 0.56, 100.03), (3, 0.56, 100.04), (0, 0, 100.05)
        ] {
            _ = mailbox.offer(
                .init(touches: Array(repeating: .init(x: 0.5, y: y), count: fingers), timestamp: timestamp),
                generation: 1, slot: 0
            )
        }
        let deliveries = mailbox.take().deliveries
        XCTAssertEqual(deliveries.map(\.frame.touches.count), [4, 4, 3, 0])
        for delivery in deliveries {
            let phase: NSEvent.Phase = switch delivery.kind {
            case .began: .began
            case .changed: .changed
            case .ended: .ended
            case .cancelled: .cancelled
            }
            sendFrame(
                fixture, phase: phase, fingers: delivery.frame.touches.count,
                x: 0.5, y: CGFloat(delivery.frame.touches.first?.y ?? 0), at: delivery.frame.timestamp
            )
            if delivery.frame.timestamp == 100.03 {
                XCTAssertTrue(actions.isOverviewGestureActive)
                XCTAssertEqual(actions.overviewTransitionProgress, 0)
            }
        }
        XCTAssertFalse(actions.isOverviewGestureActive)
        guard case .opening = actions.overviewState else { return XCTFail("Expected the single-frame flick to open") }
    }

    func testOverviewRecognitionAfterHoldUsesLastValidSample() throws {
        for (recognitionY, shouldOpen): (CGFloat, Bool) in [(0.234, false), (0.56, true)] {
            let fixture = try makeInteractiveOverviewFixture()
            let actions = fixture.controller.windowActionHandler
            defer { dismissInteractiveOverview(fixture) }
            sendFrame(fixture, phase: .began, fingers: 4, x: 0.5, y: 0.2, at: 100)
            sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.23, at: 100.95)
            sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: recognitionY, at: 101)
            XCTAssertTrue(actions.isOverviewGestureActive)
            XCTAssertEqual(actions.overviewTransitionProgress, 0)
            sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 101.01)
            if shouldOpen {
                guard case .opening = actions.overviewState
                else { return XCTFail("Expected recent fast movement to open") }
            } else {
                guard case .closed = actions.overviewState else { return XCTFail("Expected slow movement to cancel") }
            }
        }
    }

    func testSystemReduceMotionUsesDiscreteOverviewTrigger() throws {
        let fixture = try makeInteractiveOverviewFixture()
        fixture.controller.motionPolicy.systemReducesMotion = true
        let actions = fixture.controller.windowActionHandler
        defer { dismissInteractiveOverview(fixture) }

        sendFrame(fixture, phase: .began, fingers: 4, x: 0.5, y: 0.2, at: 100)
        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.24, at: 100.1)
        XCTAssertFalse(actions.isOverviewGestureActive)
        XCTAssertFalse(fixture.controller.isOverviewOpen())

        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.6, at: 100.2)

        XCTAssertFalse(actions.isOverviewGestureActive)
        guard case .open = actions.overviewState else {
            return XCTFail("Expected the discrete trigger under Reduce Motion")
        }
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.3)
        XCTAssertTrue(fixture.controller.isOverviewOpen())
    }

    func testHotkeyDuringInteractiveTrackingSuppressesGestureUntilLift() throws {
        let fixture = try makeInteractiveOverviewFixture()
        let handler = fixture.controller.mouseEventHandler
        let actions = fixture.controller.windowActionHandler
        defer { dismissInteractiveOverview(fixture) }

        sendFrame(fixture, phase: .began, fingers: 4, x: 0.5, y: 0.2, at: 100)
        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.24, at: 100.1)
        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.64, at: 100.2)
        XCTAssertGreaterThan(actions.overviewTransitionProgress, 0.5)

        actions.toggleOverview()

        XCTAssertFalse(actions.isOverviewGestureActive)
        guard case .closing = actions.overviewState else { return XCTFail("Expected the hotkey above half to close") }
        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.7, at: 100.3)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertTrue(handler.state.suppressGestureStartUntilAllTouchesLift)
        guard case .closing = actions.overviewState
        else { return XCTFail("Expected residual frames to leave the flight alone") }
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.4)
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)
    }

    func testTouchDownDuringOverviewFlightFreezesUntilLift() throws {
        let fixture = try makeInteractiveOverviewFixture()
        let handler = fixture.controller.mouseEventHandler
        let actions = fixture.controller.windowActionHandler
        defer { dismissInteractiveOverview(fixture) }
        actions.toggleOverview()
        guard case .opening = actions.overviewState
        else { return XCTFail("Expected the hotkey to start an open flight") }

        sendFrame(fixture, phase: .began, fingers: 4, x: 0.5, y: 0.2, at: 100)

        XCTAssertEqual(handler.state.gesturePhase, .armed)
        XCTAssertTrue(actions.isOverviewGestureActive)
        guard case .opening = actions.overviewState
        else { return XCTFail("Expected the caught flight to stay in .opening") }
        let caught = actions.overviewTransitionProgress
        XCTAssertLessThan(caught, 1)

        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.24, at: 100.1)
        XCTAssertEqual(handler.state.gesturePhase, .committed)
        XCTAssertEqual(actions.overviewTransitionProgress, caught, accuracy: 0.000000000001)
        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.9, at: 100.2)
        XCTAssertGreaterThan(actions.overviewTransitionProgress, 1)
        XCTAssertLessThanOrEqual(actions.overviewTransitionProgress, 1.3)

        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.3)

        XCTAssertFalse(actions.isOverviewGestureActive)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        guard case .opening = actions.overviewState
        else { return XCTFail("Expected an overscroll release to reopen") }
    }

    func testHorizontalWorkspaceSwipeSharingOverviewFingersSurvivesCommitWithAnimations() throws {
        let fixture = try makeFixture(
            workspaceFingers: .four,
            workspaceAxis: .horizontal,
            scrollGestureEnabled: true,
            columnFingers: .three
        )
        fixture.controller.setAnimationsEnabled(true)
        fixture.controller.settings.gestures.overviewGestureEnabled = true
        let handler = fixture.controller.mouseEventHandler
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 4, x: 0.8, y: 0.5, at: time)
        for step in 1 ... 8 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 4, x: 0.8 - 0.055 * CGFloat(step), y: 0.5, at: time)
            XCTAssertEqual(handler.state.gesturePhase, .committed, "step \(step)")
            XCTAssertEqual(handler.state.activeGestureMode, .workspaceSwitch(axis: .horizontal), "step \(step)")
        }
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
        XCTAssertFalse(fixture.controller.isOverviewOpen())
    }

    func testInteractiveCloseGestureConsumesScrollTail() throws {
        let fixture = try makeInteractiveOverviewFixture()
        let controller = fixture.controller
        let handler = controller.mouseEventHandler
        let actions = controller.windowActionHandler
        defer { dismissInteractiveOverview(fixture) }
        controller.setAnimationsEnabled(false)
        actions.toggleOverview()
        controller.setAnimationsEnabled(true)
        guard case .open = actions.overviewState else { return XCTFail("Expected an open overview") }

        sendFrame(fixture, phase: .began, fingers: 4, x: 0.5, y: 0.8, at: 100)
        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.76, at: 100.1)
        guard case .opening = actions.overviewState
        else { return XCTFail("Expected a close-track to live in .opening") }
        XCTAssertEqual(actions.overviewTransitionProgress, 1, accuracy: 0.000000000001)
        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.4, at: 100.2)
        XCTAssertEqual(actions.overviewTransitionProgress, 0.4, accuracy: 0.000000001)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.changed.rawValue))
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 2, phase: 0))
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))

        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.5)

        guard case .closing = actions.overviewState else { return XCTFail("Expected release below half to close") }
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)
        XCTAssertFalse(handler.state.consumeTrackpadScrollUntilAllTouchesLift)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 2, phase: 0))
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        sendFrame(fixture, phase: .began, fingers: 2, x: 0.5, y: 0.5, at: 101)
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.began.rawValue))
        XCTAssertFalse(handler.state.suppressTrackpadMomentumScroll)
    }

    private func makeInteractiveOverviewFixture() throws -> Fixture {
        let fixture = try makeFixture(workspaceSwipeEnabled: false)
        fixture.controller.setAnimationsEnabled(true)
        fixture.controller.settings.gestures.overviewGestureEnabled = true
        return fixture
    }

    private func dismissInteractiveOverview(_ fixture: Fixture) {
        fixture.controller.setAnimationsEnabled(false)
        fixture.controller.windowActionHandler.dismissOverview()
    }

    func testAmbiguousUpwardGestureDoesNotOpenOverviewOrSwitchWorkspace() throws {
        let fixture = try makeFixture(workspaceFingers: .four)
        fixture.controller.settings.gestures.overviewGestureEnabled = true
        _ = performVerticalSwipe(fixture, fingers: 4, totalUnits: 220, startTime: 100)
        XCTAssertFalse(fixture.controller.isOverviewOpen())
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
    }

    private final class GestureLivenessClock {
        var time: TimeInterval

        init(time: TimeInterval) {
            self.time = time
        }
    }

    func testHorizontalDiscreteWheelEventAdvancesOneColumnAndRequestsFocus() throws {
        let fixture = try makeFixture(workspaceSwipeEnabled: false, scrollGestureEnabled: true)
        try addColumnGestureWindows(to: fixture)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        let manager = fixture.controller.workspaceManager
        let columns = engine.columns(in: fixture.ws1)
        let first = try XCTUnwrap(columns[0].windowNodes.first)
        let second = try XCTUnwrap(columns[1].windowNodes.first)
        manager.withNiriViewportState(for: fixture.ws1) { state in
            state.selectedNodeId = first.id
            state.activeColumnIndex = 0
        }
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 1,
            wheel3: 0
        ))
        let payload = MouseEventHandler.scrollPayload(
            event, at: CGPoint(x: 800, y: 450),
            modifiersRawValue: CGEventFlags([.maskAlternate, .maskShift]).rawValue
        )
        XCTAssertFalse(payload.payload.isContinuous)
        fixture.controller.mouseEventHandler.handleScrollWheelFromTap(payload.payload)
        XCTAssertEqual(manager.niriViewportState(for: fixture.ws1).selectedNodeId, second.id)
        XCTAssertEqual(manager.pendingFocusedToken, second.token)
    }

    func testCoalescedDiscreteWheelEventsKeepBothTicksAndFocusOnlyFinalColumn() throws {
        var focusedWindowIds: [UInt32] = []
        var raiseCount = 0
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, windowId, _ in focusedWindowIds.append(windowId) },
                raiseWindow: { _ in raiseCount += 1 }
            )
        )
        try addColumnGestureWindows(to: fixture)
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let columns = try XCTUnwrap(controller.niriEngine).columns(in: fixture.ws1)
        let first = try XCTUnwrap(columns[0].windowNodes.first)
        let last = try XCTUnwrap(columns[2].windowNodes.first)
        manager.withNiriViewportState(for: fixture.ws1) { state in
            state.selectedNodeId = first.id
            state.activeColumnIndex = 0
        }
        controller.eventIntake.open(sink: controller.eventInterpreter)
        defer { controller.eventIntake.close() }
        for delta: Int32 in [1, 10] {
            let event = try XCTUnwrap(CGEvent(
                scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                wheel1: delta, wheel2: 0, wheel3: 0
            ))
            let payload = MouseEventHandler.scrollPayload(
                event, at: CGPoint(x: 800, y: 450),
                modifiersRawValue: CGEventFlags([.maskAlternate, .maskShift]).rawValue
            )
            XCTAssertTrue(controller.mouseEventHandler.receiveTapScrollWheel(
                payload.payload, traceMetadata: payload.traceMetadata
            ))
        }
        XCTAssertTrue(focusedWindowIds.isEmpty)
        controller.eventIntake.drainNow()
        XCTAssertEqual(manager.niriViewportState(for: fixture.ws1).selectedNodeId, last.id)
        XCTAssertEqual(manager.pendingFocusedToken, last.token)
        XCTAssertEqual(focusedWindowIds, [UInt32(last.token.windowId)])
        XCTAssertEqual(raiseCount, 0)
        let request = try XCTUnwrap(controller.intentLedger.activeManagedRequest)
        XCTAssertTrue(controller.intentLedger.defersRetryRaise(for: request))
    }

    private struct Fixture {
        let controller: WMController
        let monitor: Monitor
        let ws1: WorkspaceDescriptor.ID
        let ws2: WorkspaceDescriptor.ID
        let ws3: WorkspaceDescriptor.ID
    }

    private func makeSettings() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackpadWorkspaceGestureTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }

    private func makeFixture(
        workspaceSwipeEnabled: Bool = true,
        workspaceFingers: GestureFingerCount = .three,
        workspaceAxis: WorkspaceSwipeAxis = .vertical,
        scrollGestureEnabled: Bool = false,
        columnFingers: GestureFingerCount = .three,
        enableNiri: Bool = true,
        windowFocusOperations: WindowFocusOperations = WindowFocusOperations(
            activateApp: { _ in },
            focusSpecificWindow: { _, _, _ in },
            raiseWindow: { _ in }
        )
    ) throws -> Fixture {
        let controller = WMController(
            settings: makeSettings(),
            windowFocusOperations: windowFocusOperations
        )
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        controller.layoutRefreshController.workspaceSwipe = WorkspaceSwipePresentation(
            refreshController: controller.layoutRefreshController,
            previewSurface: WorkspaceSwipePreview(
                ownedWindowRegistry: controller.ownedWindowRegistry,
                hasCaptureAccess: { false }
            )
        )
        controller.settings.gestures.scrollEnabled = scrollGestureEnabled
        controller.settings.gestures.fingerCount = columnFingers
        controller.settings.gestures.workspaceSwipeEnabled = workspaceSwipeEnabled
        controller.settings.gestures.workspaceSwipeFingerCount = workspaceFingers
        controller.settings.gestures.workspaceSwipeAxis = workspaceAxis
        if enableNiri {
            controller.enableNiriLayout()
        }
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "Test"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let ws1 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let ws2 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "2", createIfMissing: true))
        let ws3 = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "3", createIfMissing: true))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(ws1, on: monitor.id))
        return Fixture(controller: controller, monitor: monitor, ws1: ws1, ws2: ws2, ws3: ws3)
    }

    private func activeWorkspace(_ fixture: Fixture) -> WorkspaceDescriptor.ID? {
        fixture.controller.workspaceManager.activeWorkspaceOrFirst(on: fixture.monitor.id)?.id
    }

    private func addManagedWindow(
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController,
        pid: pid_t,
        windowId: Int
    ) -> WindowToken {
        controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
    }

    private func addColumnGestureWindows(to fixture: Fixture) throws {
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        for index in 0 ..< 3 {
            let token = addManagedWindow(
                to: fixture.ws1,
                controller: fixture.controller,
                pid: pid_t(7_001 + index),
                windowId: 7_101 + index
            )
            _ = engine.addWindow(token: token, to: fixture.ws1, afterSelection: nil)
        }
        for column in engine.columns(in: fixture.ws1) {
            column.cachedWidth = 700
        }
    }

    private func beginCommittedColumnGesture(
        _ fixture: Fixture,
        location: CGPoint = CGPoint(x: 800, y: 450)
    ) -> TimeInterval {
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.8, y: 0.5, at: time, location: location)
        for step in 1 ... 4 {
            time += 0.01
            sendFrame(
                fixture,
                phase: .changed,
                fingers: 3,
                x: 0.8 - 0.03 * CGFloat(step),
                y: 0.5,
                at: time,
                location: location
            )
        }
        XCTAssertTrue(fixture.controller.mouseEventHandler.isViewportGestureActive)
        for _ in 0 ..< 20 {
            time += 0.01
            sendFrame(
                fixture,
                phase: .changed,
                fingers: 3,
                x: 0.68,
                y: 0.5,
                at: time,
                location: location
            )
        }
        return time
    }

    private func configureSecondMonitor(
        _ fixture: Fixture,
        workspaceNames: Set<String> = ["6", "7"]
    ) throws -> (monitor: Monitor, workspaceIds: [WorkspaceDescriptor.ID]) {
        let monitor = Monitor(
            id: .init(displayId: 2),
            displayId: 2,
            frame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 1600, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "TestB"
        )
        let controller = fixture.controller
        controller.settings.workspaces.configurations = controller.settings.workspaces.configurations
            .map { configuration in
                var configuration = configuration
                configuration.monitorAssignment = workspaceNames.contains(configuration.name)
                    ? .specificDisplay(OutputId(from: monitor))
                    : .specificDisplay(OutputId(from: fixture.monitor))
                return configuration
            }
        controller.workspaceManager.applyMonitorConfigurationChange([fixture.monitor, monitor])
        controller.workspaceManager.applySettings()
        let workspaceIds = try workspaceNames.sorted().map { name in
            try XCTUnwrap(controller.workspaceManager.workspaceId(for: name, createIfMissing: true))
        }
        return (monitor, workspaceIds)
    }

    private func withBlockedLayoutRefreshes<T>(
        _ fixture: Fixture,
        _ body: () throws -> T
    ) rethrows -> T {
        let blocker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let refreshController = fixture.controller.layoutRefreshController
        refreshController.layoutState.activeRefreshTask = blocker
        refreshController.layoutState.activeRefresh = .init(
            kind: .immediateRelayout,
            reason: .workspaceTransition,
            affectedWorkspaceIds: [fixture.ws1]
        )
        defer {
            blocker.cancel()
            refreshController.layoutState.activeRefreshTask = nil
            refreshController.layoutState.activeRefresh = nil
            refreshController.layoutState.pendingRefresh = nil
        }
        return try body()
    }

    private func touches(_ count: Int, x: CGFloat, y: CGFloat) -> [MouseEventHandler.GestureTouchSample] {
        (0 ..< count).map { _ in
            MouseEventHandler.GestureTouchSample(phase: .moved, normalizedPosition: CGPoint(x: x, y: y))
        }
    }

    private func sendFrame(
        _ fixture: Fixture,
        phase: NSEvent.Phase,
        fingers: Int,
        x: CGFloat,
        y: CGFloat,
        at timestamp: TimeInterval,
        location: CGPoint = CGPoint(x: 800, y: 450),
        senderId: UInt64? = 0x637,
        slot: Int = 0
    ) {
        let handler = fixture.controller.mouseEventHandler
        var contacts = handler.state.contactSessions
        if contacts.generation == 0 { contacts.generation = 1 }
        if fingers > 0, phase == .began || contacts.sessions[slot] == 0 {
            contacts.sessions[slot] += 1
            handler.updateContactSessions(contacts)
        }
        let contact = MultitouchContactSession(
            generation: contacts.generation, slot: slot, session: contacts.sessions[slot], senderId: senderId
        )
        let snapshot = MouseEventHandler.GestureEventSnapshot(
            location: location,
            phaseRawValue: phase.rawValue,
            timestamp: timestamp,
            touches: phase == .ended || phase == .cancelled ? [] : touches(fingers, x: x, y: y),
            contactSession: contact
        )
        fixture.controller.mouseEventHandler.receiveTapGestureEvent(snapshot)
    }

    private func performVerticalSwipe(
        _ fixture: Fixture,
        fingers: Int = 3,
        from startY: CGFloat = 0.2,
        totalUnits: CGFloat,
        startTime: TimeInterval,
        endPhase: NSEvent.Phase = .ended,
        location: CGPoint = CGPoint(x: 800, y: 450)
    ) -> TimeInterval {
        let steps = 8
        let stepNormalized = totalUnits / 500.0 / CGFloat(steps)
        var time = startTime
        sendFrame(fixture, phase: .began, fingers: fingers, x: 0.5, y: startY, at: time, location: location)
        for step in 1 ... steps {
            time += 0.01
            sendFrame(
                fixture,
                phase: .changed,
                fingers: fingers,
                x: 0.5,
                y: startY + stepNormalized * CGFloat(step),
                at: time,
                location: location
            )
        }
        time += 0.01
        sendFrame(fixture, phase: endPhase, fingers: 0, x: 0, y: 0, at: time, location: location)
        return time
    }

    func testVerticalSwipeSwitchesToNextWorkspaceExactlyOnce() throws {
        let fixture = try makeFixture()
        _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
    }

    func testVerticalSwipeDownSwitchesToPreviousWithWrapAround() throws {
        let fixture = try makeFixture()
        let lastWorkspace = fixture.controller.workspaceManager.workspaces(on: fixture.monitor.id).last?.id
        XCTAssertNotEqual(lastWorkspace, fixture.ws1)
        _ = performVerticalSwipe(fixture, totalUnits: -220, startTime: 100)
        XCTAssertEqual(activeWorkspace(fixture), lastWorkspace)
    }

    func testInvertedDirectionFlipsVerticalMapping() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.gestures.invertDirection = false
        let lastWorkspace = fixture.controller.workspaceManager.workspaces(on: fixture.monitor.id).last?.id
        _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100)
        XCTAssertEqual(activeWorkspace(fixture), lastWorkspace)
    }

    func testSlowDragBelowDistanceThresholdDoesNotSwitch() throws {
        let fixture = try makeFixture()
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        for step in 1 ... 5 {
            time += 0.02
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.2 + 0.024 * CGFloat(step), at: time)
        }
        for _ in 0 ..< 10 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.32, at: time)
        }
        time += 0.005
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
    }

    func testFastFlickBelowDistanceThresholdSwitchesOnRelease() throws {
        let fixture = try makeFixture()
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        for step in 1 ... 3 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.2 + 0.04 * CGFloat(step), at: time)
        }
        time += 0.005
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
    }

    func testCommitCrossingFrameContributesExactlyOneVelocitySample() throws {
        let fixture = try makeFixture()
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        for step in 1 ... 3 {
            time += 0.02
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.2 + 0.03 * CGFloat(step), at: time)
        }
        time += 0.02
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
    }

    func testCancelledGestureNeverFires() throws {
        let fixture = try makeFixture()
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        for step in 1 ... 3 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.2 + 0.04 * CGFloat(step), at: time)
        }
        time += 0.005
        sendFrame(fixture, phase: .cancelled, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
    }

    func testTerminalFrameClearsLatchesWhenPreconditionsFail() throws {
        let fixture = try makeFixture()
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        time += 0.01
        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.24, at: time)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .committed)

        fixture.controller.isEnabled = false
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)

        let handler = fixture.controller.mouseEventHandler
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)
        XCTAssertFalse(handler.state.consumeTrackpadScrollUntilAllTouchesLift)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)

        fixture.controller.isEnabled = true
        time += 0.01
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        XCTAssertEqual(handler.state.gesturePhase, .armed)
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
    }

    func testClaimedSessionConsumesScrollAfterEligibilityChanges() throws {
        let fixture = try makeFixture()
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        time += 0.01
        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.24, at: time)
        XCTAssertTrue(fixture.controller.mouseEventHandler.isTrackpadSwipeSessionActive)

        fixture.controller.isEnabled = false
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.changed.rawValue))
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 2, phase: 0))

        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        let handler = fixture.controller.mouseEventHandler
        XCTAssertFalse(handler.isTrackpadSwipeSessionActive)
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)
        XCTAssertFalse(handler.state.consumeTrackpadScrollUntilAllTouchesLift)
        XCTAssertTrue(handler.state.suppressTrackpadMomentumScroll)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 2, phase: 0))
    }

    func testClaimedSessionConsumesPhaseLessScrollEvents() throws {
        let fixture = try makeFixture()
        let handler = fixture.controller.mouseEventHandler

        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: 100)

        XCTAssertTrue(handler.isTrackpadSwipeSessionActive)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
    }

    func testCompletedWorkspaceSwipeConsumesPhaseLessScrollTail() throws {
        let fixture = try makeFixture()
        let handler = fixture.controller.mouseEventHandler

        _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100)

        XCTAssertFalse(handler.isTrackpadSwipeSessionActive)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
    }

    func testRapidSuccessiveSwipesRejectStaleFocusHandoff() throws {
        var focusedWindowIds: [UInt32] = []
        let fixture = try makeFixture(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, windowId, _ in focusedWindowIds.append(windowId) },
                raiseWindow: { _ in }
            )
        )
        let manager = fixture.controller.workspaceManager
        let ws2Token = addManagedWindow(
            to: fixture.ws2,
            controller: fixture.controller,
            pid: 7_002,
            windowId: 7_102
        )
        let ws3Token = addManagedWindow(
            to: fixture.ws3,
            controller: fixture.controller,
            pid: 7_003,
            windowId: 7_103
        )
        XCTAssertTrue(manager.rememberFocus(ws2Token, in: fixture.ws2))
        XCTAssertTrue(manager.rememberFocus(ws3Token, in: fixture.ws3))

        try withBlockedLayoutRefreshes(fixture) {
            let firstEnd = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100)
            _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: firstEnd + 0.05)

            let actions = try XCTUnwrap(
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions
            )
            XCTAssertEqual(actions.count, 2)
            XCTAssertFalse(actions[0].isCurrent(using: manager))
            XCTAssertTrue(actions[1].isCurrent(using: manager))
            for action in actions {
                action.runIfCurrent(using: manager)
            }

            XCTAssertEqual(activeWorkspace(fixture), fixture.ws3)
            XCTAssertEqual(focusedWindowIds, [UInt32(ws3Token.windowId)])
        }
    }

    func testEmptyWorkspaceTargetClearsManagedFocusAfterLayout() throws {
        var activatedPIDs: [pid_t] = []
        let fixture = try makeFixture(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { activatedPIDs.append($0) },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let manager = fixture.controller.workspaceManager
        XCTAssertFalse(manager.nativeFocusOwner.isExternal)

        try withBlockedLayoutRefreshes(fixture) {
            fixture.controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)
            let action = try XCTUnwrap(
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
            )
            XCTAssertTrue(action.isCurrent(using: manager))
            XCTAssertTrue(activatedPIDs.isEmpty)
            action.runIfCurrent(using: manager)

            XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
            XCTAssertEqual(manager.nativeFocusOwner, .none)
            XCTAssertNil(manager.pendingFocusedToken)
            XCTAssertEqual(activatedPIDs, [getpid()])
        }
    }

    func testEmptyWorkspaceTargetClearsManagedFocusWhenLayoutIsInvalidated() throws {
        var activatedPIDs: [pid_t] = []
        let fixture = try makeFixture(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { activatedPIDs.append($0) },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        let manager = fixture.controller.workspaceManager
        let token = addManagedWindow(to: fixture.ws1, controller: fixture.controller, pid: 7_010, windowId: 7_110)
        XCTAssertTrue(manager.confirmManagedFocus(token, in: fixture.ws1, activateWorkspaceOnMonitor: false))
        XCTAssertEqual(manager.nativeFocusOwner, .managed(token))

        try withBlockedLayoutRefreshes(fixture) {
            fixture.controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)
            manager.invalidateLayout(for: [fixture.ws2])
            let action = try XCTUnwrap(
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
            )
            XCTAssertFalse(action.isCurrent(using: manager))
            action.runIfCurrent(using: manager)

            XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
            XCTAssertEqual(manager.nativeFocusOwner, .none)
            XCTAssertNil(manager.pendingFocusedToken)
            XCTAssertEqual(activatedPIDs, [getpid()])
        }
    }

    func testRapidSwipeThroughEmptyWorkspaceRejectsStaleClear() throws {
        var activatedPIDs: [pid_t] = []
        var focusedWindowIds: [UInt32] = []
        let fixture = try makeFixture(
            windowFocusOperations: WindowFocusOperations(
                activateApp: { activatedPIDs.append($0) },
                focusSpecificWindow: { _, windowId, _ in focusedWindowIds.append(windowId) },
                raiseWindow: { _ in }
            )
        )
        let manager = fixture.controller.workspaceManager
        let ws1Token = addManagedWindow(to: fixture.ws1, controller: fixture.controller, pid: 7_011, windowId: 7_111)
        let ws3Token = addManagedWindow(to: fixture.ws3, controller: fixture.controller, pid: 7_013, windowId: 7_113)
        XCTAssertTrue(manager.confirmManagedFocus(ws1Token, in: fixture.ws1, activateWorkspaceOnMonitor: false))
        XCTAssertTrue(manager.rememberFocus(ws3Token, in: fixture.ws3))

        try withBlockedLayoutRefreshes(fixture) {
            let firstEnd = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100)
            _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: firstEnd + 0.05)

            let actions = try XCTUnwrap(
                fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions
            )
            XCTAssertEqual(actions.count, 2)
            XCTAssertFalse(actions[0].isCurrent(using: manager))
            XCTAssertTrue(actions[1].isCurrent(using: manager))
            for action in actions {
                action.runIfCurrent(using: manager)
            }

            XCTAssertEqual(activeWorkspace(fixture), fixture.ws3)
            XCTAssertEqual(focusedWindowIds, [UInt32(ws3Token.windowId)])
            XCTAssertEqual(manager.pendingFocusedToken, ws3Token)
            XCTAssertEqual(manager.nativeFocusOwner, .managed(ws1Token))
            XCTAssertFalse(activatedPIDs.contains(getpid()))
        }
    }

    func testSharedCountHorizontalSwipeRoutesToColumnScroll() throws {
        let fixture = try makeFixture(scrollGestureEnabled: true)
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.2, y: 0.5, at: time)
        for step in 1 ... 4 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.2 + 0.02 * CGFloat(step), y: 0.5, at: time)
        }
        XCTAssertTrue(fixture.controller.mouseEventHandler.isViewportGestureActive)
        XCTAssertTrue(fixture.controller.mouseEventHandler.isTrackpadSwipeSessionActive)
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
    }

    func testSharedCountHorizontalSwipeAppliesAndFinalizesNiriViewport() throws {
        var finalOffsets: [TrackpadScrollStyle: CGFloat] = [:]
        var finalIndexes: [TrackpadScrollStyle: Int] = [:]
        var momentumViewportScale: CGFloat?

        for style in TrackpadScrollStyle.allCases {
            var focusedWindowIds: [UInt32] = []
            let fixture = try makeFixture(
                scrollGestureEnabled: true,
                windowFocusOperations: WindowFocusOperations(
                    activateApp: { _ in },
                    focusSpecificWindow: { _, windowId, _ in focusedWindowIds.append(windowId) },
                    raiseWindow: { _ in }
                )
            )
            fixture.controller.settings.gestures.trackpadScrollStyle = style
            try addColumnGestureWindows(to: fixture)
            let manager = fixture.controller.workspaceManager
            let driver = manager.animationDriver
            let semanticOffset = manager.niriViewportState(for: fixture.ws1).viewOffset
            if style == .momentum {
                let geometry = fixture.controller.niriInteractionGeometry(for: fixture.monitor, scale: 2)
                momentumViewportScale = geometry.workingFrame.width / fixture.monitor.visibleFrame.width
            }

            var time = beginCommittedColumnGesture(fixture)

            XCTAssertTrue(driver.trackpadGestureActive(in: fixture.ws1))
            XCTAssertNotEqual(
                driver.liveViewOffset(in: fixture.ws1, semanticOffset: semanticOffset),
                semanticOffset
            )

            time += 0.01
            sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
            XCTAssertFalse(driver.hasGesture(in: fixture.ws1))
            XCTAssertTrue(driver.hasMotion(in: fixture.ws1))
            XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
            XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
            let finalState = manager.niriViewportState(for: fixture.ws1)
            finalOffsets[style] = finalState.viewOffset
            finalIndexes[style] = finalState.activeColumnIndex
            XCTAssertEqual(focusedWindowIds, [UInt32(7_101 + finalState.activeColumnIndex)])
            XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.origin, .pointerHover)
        }

        let snapOffset = try XCTUnwrap(finalOffsets[.snap])
        let momentumOffset = try XCTUnwrap(finalOffsets[.momentum])
        XCTAssertEqual(finalIndexes[.snap], 2)
        XCTAssertEqual(finalIndexes[.momentum], 0)
        XCTAssertLessThan(snapOffset, 0)
        XCTAssertEqual(momentumOffset, 300 * (try XCTUnwrap(momentumViewportScale)), accuracy: 0.001)
        XCTAssertNotEqual(snapOffset, momentumOffset)
    }

    func testCancelledColumnGestureDoesNotFocusLandingWindow() throws {
        var focusedWindowIds: [UInt32] = []
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, windowId, _ in focusedWindowIds.append(windowId) },
                raiseWindow: { _ in }
            )
        )
        try addColumnGestureWindows(to: fixture)
        var time = beginCommittedColumnGesture(fixture)

        time += 0.01
        sendFrame(fixture, phase: .cancelled, fingers: 0, x: 0, y: 0, at: time)

        XCTAssertTrue(focusedWindowIds.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testDisabledColumnGestureAbortDoesNotFocusLandingWindow() throws {
        var focusedWindowIds: [UInt32] = []
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, windowId, _ in focusedWindowIds.append(windowId) },
                raiseWindow: { _ in }
            )
        )
        try addColumnGestureWindows(to: fixture)
        var time = beginCommittedColumnGesture(fixture)

        fixture.controller.isEnabled = false
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)

        XCTAssertTrue(focusedWindowIds.isEmpty)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testLostColumnGestureCommitsOffsetAndReleasesInputSession() throws {
        var focusOperationCount = 0
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in focusOperationCount += 1 },
                focusSpecificWindow: { _, _, _ in focusOperationCount += 1 },
                raiseWindow: { _ in focusOperationCount += 1 }
            )
        )
        try addColumnGestureWindows(to: fixture)
        let manager = fixture.controller.workspaceManager
        let driver = manager.animationDriver
        let livenessClock = GestureLivenessClock(time: 1)
        driver.gestureLivenessNow = { livenessClock.time }

        _ = beginCommittedColumnGesture(fixture)

        let handler = fixture.controller.mouseEventHandler
        let semanticOffset = manager.niriViewportState(for: fixture.ws1).viewOffset
        let expectedOffset = try XCTUnwrap(
            driver.liveViewOffset(in: fixture.ws1, semanticOffset: semanticOffset)
        )
        XCTAssertEqual(handler.state.gesturePhase, .committed)
        XCTAssertTrue(handler.isTrackpadSwipeSessionActive)
        XCTAssertEqual(
            fixture.controller.niriLayoutHandler.scrollAnimationByDisplay[fixture.monitor.displayId],
            fixture.ws1
        )
        focusOperationCount = 0
        livenessClock.time = 2

        fixture.controller.niriLayoutHandler.tickScrollAnimation(
            targetTime: 2,
            displayId: fixture.monitor.displayId
        )

        XCTAssertEqual(
            manager.niriViewportState(for: fixture.ws1).viewOffset,
            expectedOffset,
            accuracy: 0.001
        )
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(handler.isTrackpadSwipeSessionActive)
        XCTAssertFalse(
            scrollVerdict(
                fixture,
                momentumPhase: 0,
                phase: CGScrollPhase.changed.rawValue
            )
        )
        XCTAssertEqual(focusOperationCount, 0)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertFalse(driver.hasMotion(in: fixture.ws1))
        XCTAssertNil(
            fixture.controller.niriLayoutHandler.scrollAnimationByDisplay[fixture.monitor.displayId]
        )
        XCTAssertNil(
            fixture.controller.layoutRefreshController.layoutState.displayLinksByDisplay[fixture.monitor.displayId]
        )
    }

    func testDisplayLinkCreationFailureSettlesGestureWithoutFocus() throws {
        var focusOperationCount = 0
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in focusOperationCount += 1 },
                focusSpecificWindow: { _, _, _ in focusOperationCount += 1 },
                raiseWindow: { _ in focusOperationCount += 1 }
            )
        )
        try addColumnGestureWindows(to: fixture)
        let manager = fixture.controller.workspaceManager
        let handler = fixture.controller.mouseEventHandler
        let semanticOffset = manager.niriViewportState(for: fixture.ws1).viewOffset
        fixture.controller.layoutRefreshController.displayLinkActivationForTests = nil
        fixture.controller.layoutRefreshController.displayLinkCreationAllowedForTests = { _ in false }
        focusOperationCount = 0

        sendFrame(fixture, phase: .began, fingers: 3, x: 0.8, y: 0.5, at: 100)
        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.74, y: 0.5, at: 100.01)

        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(handler.isTrackpadSwipeSessionActive)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: fixture.ws1))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.ws1))
        XCTAssertNotEqual(manager.niriViewportState(for: fixture.ws1).viewOffset, semanticOffset)
        XCTAssertEqual(focusOperationCount, 0)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
        XCTAssertTrue(handler.state.suppressGestureStartUntilAllTouchesLift)

        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.7, y: 0.5, at: 100.02)
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.03)
    }

    func testInactiveWorkspaceAbortSettlesGestureWithoutFocus() throws {
        var focusOperationCount = 0
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in focusOperationCount += 1 },
                focusSpecificWindow: { _, _, _ in focusOperationCount += 1 },
                raiseWindow: { _ in focusOperationCount += 1 }
            )
        )
        try addColumnGestureWindows(to: fixture)
        _ = beginCommittedColumnGesture(fixture)
        let manager = fixture.controller.workspaceManager
        let handler = fixture.controller.mouseEventHandler
        let semanticOffset = manager.niriViewportState(for: fixture.ws1).viewOffset
        let expectedOffset = try XCTUnwrap(
            manager.animationDriver.liveViewOffset(in: fixture.ws1, semanticOffset: semanticOffset)
        )
        focusOperationCount = 0

        fixture.controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: true)

        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
        XCTAssertEqual(
            manager.niriViewportState(for: fixture.ws1).viewOffset,
            expectedOffset,
            accuracy: 0.001
        )
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: fixture.ws1))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.ws1))
        XCTAssertEqual(focusOperationCount, 0)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testMonitorLossSettlesGestureWithoutFocus() throws {
        var focusOperationCount = 0
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in focusOperationCount += 1 },
                focusSpecificWindow: { _, _, _ in focusOperationCount += 1 },
                raiseWindow: { _ in focusOperationCount += 1 }
            )
        )
        try addColumnGestureWindows(to: fixture)
        let manager = fixture.controller.workspaceManager
        let semanticOffset = manager.niriViewportState(for: fixture.ws1).viewOffset
        _ = beginCommittedColumnGesture(fixture)
        let expectedOffset = try XCTUnwrap(
            manager.animationDriver.liveViewOffset(in: fixture.ws1, semanticOffset: semanticOffset)
        )
        focusOperationCount = 0

        fixture.controller.layoutRefreshController.cleanupForMonitorDisconnect(
            displayId: fixture.monitor.displayId,
            migrateAnimations: false
        )

        XCTAssertEqual(manager.niriViewportState(for: fixture.ws1).viewOffset, expectedOffset, accuracy: 0.001)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: fixture.ws1))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.ws1))
        XCTAssertEqual(focusOperationCount, 0)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testResetSettlesGestureWithoutStartingPostResetRefresh() throws {
        var focusOperationCount = 0
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in focusOperationCount += 1 },
                focusSpecificWindow: { _, _, _ in focusOperationCount += 1 },
                raiseWindow: { _ in focusOperationCount += 1 }
            )
        )
        try addColumnGestureWindows(to: fixture)
        let manager = fixture.controller.workspaceManager
        let semanticOffset = manager.niriViewportState(for: fixture.ws1).viewOffset
        _ = beginCommittedColumnGesture(fixture)
        let expectedOffset = try XCTUnwrap(
            manager.animationDriver.liveViewOffset(in: fixture.ws1, semanticOffset: semanticOffset)
        )
        focusOperationCount = 0
        fixture.controller.hasStartedServices = false

        fixture.controller.layoutRefreshController.resetState()

        XCTAssertEqual(manager.niriViewportState(for: fixture.ws1).viewOffset, expectedOffset, accuracy: 0.001)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: fixture.ws1))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.ws1))
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.activeRefreshTask)
        XCTAssertEqual(focusOperationCount, 0)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)
    }

    func testWorkspaceMonitorMoveSettlesGestureBeforeStateMutation() throws {
        let fixture = try makeFixture(workspaceSwipeEnabled: false, scrollGestureEnabled: true)
        let target = try configureSecondMonitor(fixture)
        try addColumnGestureWindows(to: fixture)
        let manager = fixture.controller.workspaceManager
        let semanticOffset = manager.niriViewportState(for: fixture.ws1).viewOffset
        _ = beginCommittedColumnGesture(fixture)
        let expectedOffset = try XCTUnwrap(
            manager.animationDriver.liveViewOffset(in: fixture.ws1, semanticOffset: semanticOffset)
        )

        let outcome = fixture.controller.workspaceNavigationHandler.moveWorkspaceToMonitor(
            fixture.ws1,
            direction: .right,
            force: true
        )

        XCTAssertNotNil(outcome)
        XCTAssertEqual(manager.monitorForWorkspace(fixture.ws1)?.id, target.monitor.id)
        XCTAssertEqual(manager.niriViewportState(for: fixture.ws1).viewOffset, expectedOffset, accuracy: 0.001)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: fixture.ws1))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.ws1))
    }

    func testRuntimeMonitorOverrideClearSettlesGestureBeforeMotionRemoval() throws {
        let fixture = try makeFixture(workspaceSwipeEnabled: false, scrollGestureEnabled: true)
        let target = try configureSecondMonitor(fixture)
        try addColumnGestureWindows(to: fixture)
        XCTAssertNotNil(fixture.controller.workspaceNavigationHandler.moveWorkspaceToMonitor(
            fixture.ws1,
            direction: .right,
            force: true
        ))
        let manager = fixture.controller.workspaceManager
        let semanticOffset = manager.niriViewportState(for: fixture.ws1).viewOffset
        _ = beginCommittedColumnGesture(
            fixture,
            location: CGPoint(x: target.monitor.frame.midX, y: target.monitor.frame.midY)
        )
        let expectedOffset = try XCTUnwrap(
            manager.animationDriver.liveViewOffset(in: fixture.ws1, semanticOffset: semanticOffset)
        )

        fixture.controller.updateWorkspaceConfig()

        XCTAssertEqual(manager.monitorForWorkspace(fixture.ws1)?.id, fixture.monitor.id)
        XCTAssertEqual(manager.niriViewportState(for: fixture.ws1).viewOffset, expectedOffset, accuracy: 0.001)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: fixture.ws1))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.ws1))
    }

    func testViewportForgetSettlesGestureBeforeRemovingViewportState() throws {
        let fixture = try makeFixture(workspaceSwipeEnabled: false, scrollGestureEnabled: true)
        try addColumnGestureWindows(to: fixture)
        let manager = fixture.controller.workspaceManager
        manager.updateNiriViewportState(ViewportState(), for: fixture.ws1)
        _ = beginCommittedColumnGesture(fixture)

        XCTAssertNotNil(manager.reconcileSnapshot().viewports[fixture.ws1])

        manager.recordReconcileEvent(
            .viewportForgotten(workspaceIds: [fixture.ws1], source: .workspaceManager)
        )

        XCTAssertNil(manager.reconcileSnapshot().viewports[fixture.ws1])
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertFalse(manager.animationDriver.hasMotion(in: fixture.ws1))
        XCTAssertFalse(fixture.controller.niriLayoutHandler.hasScrollAnimation(for: fixture.ws1))
    }

    func testExpiredGestureDoesNotReleaseNewerOrDifferentSession() throws {
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true
        )
        try addColumnGestureWindows(to: fixture)
        _ = beginCommittedColumnGesture(fixture)
        let handler = fixture.controller.mouseEventHandler
        let driver = fixture.controller.workspaceManager.animationDriver
        let expiredSessionID = try XCTUnwrap(driver.gestureSessionID(in: fixture.ws1))
        let newerSessionID = try XCTUnwrap(
            driver.beginGesture(in: fixture.ws1, isTrackpad: true, timestamp: 101)
        )
        handler.applyTrackpadViewportScrollDelta(
            1,
            engine: try XCTUnwrap(fixture.controller.niriEngine),
            wsId: fixture.ws1,
            monitor: fixture.monitor,
            orientation: .horizontal,
            timestamp: 101
        )
        XCTAssertNotEqual(expiredSessionID, newerSessionID)

        handler.handleExpiredViewportGesture(
            in: fixture.ws2,
            sessionID: newerSessionID
        )
        XCTAssertFalse(handler.terminateViewportGesture(
            in: fixture.ws1,
            sessionID: expiredSessionID,
            disposition: .settleLiveOffset
        ))

        XCTAssertEqual(handler.state.gesturePhase, .committed)
        XCTAssertTrue(handler.isTrackpadSwipeSessionActive)
        XCTAssertEqual(handler.state.viewportGestureSessionID, newerSessionID)
        XCTAssertTrue(driver.hasGesture(in: fixture.ws1))
        fixture.controller.niriLayoutHandler.cancelActiveAnimations(for: fixture.ws1)
        handler.handleAppVisibilityChanged()
    }

    func testWorkspaceOnlyNiriGestureDoesNotClaimViewportWhileArmed() throws {
        let fixture = try makeFixture()
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: 100)

        XCTAssertTrue(fixture.controller.mouseEventHandler.isTrackpadSwipeSessionActive)
        XCTAssertFalse(fixture.controller.mouseEventHandler.isViewportGestureActive)

        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.01)
    }

    func testDwindleWorkspaceGestureDoesNotClaimViewportWhileArmed() throws {
        let fixture = try makeFixture(scrollGestureEnabled: true, enableNiri: false)
        fixture.controller.settings.workspaces.configurations = fixture.controller.settings.workspaces.configurations
            .map {
                $0.with(layoutType: .dwindle)
            }
        fixture.controller.enableDwindleLayout()
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: 100)

        XCTAssertTrue(fixture.controller.mouseEventHandler.isTrackpadSwipeSessionActive)
        XCTAssertFalse(fixture.controller.mouseEventHandler.isViewportGestureActive)

        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.01)
    }

    func testDistinctWorkspaceFingerCountDoesNotClaimViewportWhileArmed() throws {
        let fixture = try makeFixture(
            workspaceFingers: .four,
            scrollGestureEnabled: true,
            columnFingers: .three
        )
        sendFrame(fixture, phase: .began, fingers: 4, x: 0.5, y: 0.2, at: 100)

        XCTAssertTrue(fixture.controller.mouseEventHandler.isTrackpadSwipeSessionActive)
        XCTAssertFalse(fixture.controller.mouseEventHandler.isViewportGestureActive)

        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.01)
    }

    func testWorkspaceSwipeSeparatesSessionFromViewportPredicate() throws {
        let fixture = try makeFixture(scrollGestureEnabled: true)
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        XCTAssertTrue(fixture.controller.mouseEventHandler.isTrackpadSwipeSessionActive)
        XCTAssertTrue(fixture.controller.mouseEventHandler.isViewportGestureActive)
        for step in 1 ... 6 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.2 + 0.06 * CGFloat(step), at: time)
        }
        XCTAssertTrue(fixture.controller.mouseEventHandler.isTrackpadSwipeSessionActive)
        XCTAssertFalse(fixture.controller.mouseEventHandler.isViewportGestureActive)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
    }

    func testOffAxisRejectionLatchesUntilFullLift() throws {
        let fixture = try makeFixture()
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.2, y: 0.5, at: time)
        time += 0.01
        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.26, y: 0.5, at: time)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertTrue(fixture.controller.mouseEventHandler.state.suppressGestureStartUntilAllTouchesLift)
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.changed.rawValue))
        for step in 1 ... 8 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.26, y: 0.5 + 0.08 * CGFloat(step), at: time)
        }
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertFalse(fixture.controller.mouseEventHandler.state.suppressGestureStartUntilAllTouchesLift)
        _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: time + 0.05)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
    }

    func testOwnedTailSkipsIntakeWhileExternalAndUnidentifiedScrollRemainIndependent() throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        controller.eventIntake.open(sink: controller.eventInterpreter)
        controller.eventIntake.beginPerformanceCapture()
        defer { controller.eventIntake.close() }
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: 100)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.01)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        XCTAssertEqual(controller.eventIntake.performanceSnapshot()?.acceptedEvents, 0)
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: 0, senderId: nil))
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: 0, senderId: 0x999))
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: 0, isContinuous: false))
        XCTAssertEqual(controller.eventIntake.performanceSnapshot()?.acceptedEvents, 3)
    }

    func testFreshTwoFingerContactRetiresCompletedTail() throws {
        let fixture = try makeFixture()
        _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        sendFrame(fixture, phase: .began, fingers: 2, x: 0.5, y: 0.5, at: 101)
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
    }

    func testOverviewPhaseLessTailRetiresBeforeEligibilityFiltering() throws {
        let fixture = try makeFixture(workspaceSwipeEnabled: false)
        fixture.controller.setAnimationsEnabled(false)
        fixture.controller.settings.gestures.overviewGestureEnabled = true
        defer { if fixture.controller.isOverviewOpen() { fixture.controller.windowActionHandler.toggleOverview() } }
        sendFrame(fixture, phase: .began, fingers: 4, x: 0.5, y: 0.2, at: 100)
        sendFrame(fixture, phase: .changed, fingers: 4, x: 0.5, y: 0.6, at: 100.1)
        XCTAssertTrue(fixture.controller.isOverviewOpen())
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.2)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        sendFrame(fixture, phase: .began, fingers: 2, x: 0.5, y: 0.5, at: 100.21)
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
    }

    func testColumnFullReleaseAndPartialLiftRetainPhaseLessTail() throws {
        for partialLift in [false, true] {
            let fixture = try makeFixture(workspaceSwipeEnabled: false, scrollGestureEnabled: true)
            try addColumnGestureWindows(to: fixture)
            let time = beginCommittedColumnGesture(fixture)
            sendFrame(
                fixture,
                phase: partialLift ? .changed : .ended,
                fingers: partialLift ? 2 : 0,
                x: 0.68,
                y: 0.5,
                at: time + 0.01
            )
            XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
            if partialLift {
                sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time + 0.02)
                XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
            }
        }
    }

    func testRejectedGestureDoesNotRetainPhaseLessTail() throws {
        for changeFingerCount in [false, true] {
            let fixture = try makeFixture()
            sendFrame(fixture, phase: .began, fingers: 3, x: 0.2, y: 0.5, at: 100)
            sendFrame(
                fixture,
                phase: .changed,
                fingers: changeFingerCount ? 2 : 3,
                x: 0.3,
                y: 0.5,
                at: 100.01
            )
            XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
            sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.02)
            XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        }
    }

    func testRetainedSourcesRemainIndependentAcrossCancellationAndVisibilityReset() throws {
        let fixture = try makeFixture()
        let handler = fixture.controller.mouseEventHandler
        for slot in 0 ..< 2 {
            let sender = UInt64(0x637 + slot)
            sendFrame(
                fixture,
                phase: .began,
                fingers: 3,
                x: 0.5,
                y: 0.2,
                at: Double(100 + slot),
                senderId: sender,
                slot: slot
            )
            sendFrame(
                fixture,
                phase: .cancelled,
                fingers: 0,
                x: 0,
                y: 0,
                at: Double(100 + slot) + 0.01,
                senderId: sender,
                slot: slot
            )
        }
        handler.handleAppVisibilityChanged()
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0, senderId: 0x637))
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0, senderId: 0x638))
        sendFrame(fixture, phase: .began, fingers: 2, x: 0.5, y: 0.5, at: 102)
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: 0, senderId: 0x637))
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0, senderId: 0x638))
        handler.resetForMultitouchSourceReplacement()
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: 0, senderId: 0x638))
    }

    func testNewContactFactsPreventOldTerminalFromReacquiringTail() throws {
        let fixture = try makeFixture()
        let handler = fixture.controller.mouseEventHandler
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: 100)
        let oldContact = try XCTUnwrap(handler.state.lockedGestureContext?.contactSession)
        var latest = handler.state.contactSessions
        latest.sessions[0] += 1
        handler.updateContactSessions(latest)
        handler.receiveTapGestureEvent(.init(
            location: CGPoint(x: 800, y: 450),
            phaseRawValue: NSEvent.Phase.ended.rawValue,
            timestamp: 100.01,
            touches: [],
            contactSession: oldContact
        ))
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        XCTAssertTrue(handler.state.consumedTrackpadSessions.isEmpty)
    }

    func testScrollTapDrainsQueuedFirstGestureAndFreshTwoFingerStart() async throws {
        let fixture = try makeFixture()
        let harness = await installRecoveringMultitouchSource(fixture)
        defer {
            fixture.controller.mouseEventHandler.cleanup()
            harness.sleeper.resumeAll()
        }
        harness.backend.emitFrame(
            registryId: 303,
            touches: Array(repeating: (x: 0.5, y: 0.2), count: 3),
            timestamp: 100
        )
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        harness.backend.emitFrame(registryId: 303, touches: [], timestamp: 100.01)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        harness.backend.emitFrame(
            registryId: 303,
            touches: Array(repeating: (x: 0.5, y: 0.5), count: 2),
            timestamp: 100.02
        )
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        await drainMultitouchTasks()
    }

    func testNonOwnerFreshContactRetiresItsOldTailThroughSynchronousDrain() async throws {
        let fixture = try makeFixture()
        let harness = await installRecoveringMultitouchSource(fixture, includeSecondDevice: true)
        defer {
            fixture.controller.mouseEventHandler.cleanup()
            harness.sleeper.resumeAll()
        }
        harness.backend.emitFrame(
            registryId: 303,
            touches: Array(repeating: (x: 0.5, y: 0.2), count: 3),
            timestamp: 100
        )
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        harness.backend.emitFrame(registryId: 303, touches: [], timestamp: 100.01)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        harness.backend.emitFrame(
            registryId: 304,
            touches: Array(repeating: (x: 0.5, y: 0.2), count: 3),
            timestamp: 100.02
        )
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0, senderId: 0x638))
        harness.backend.emitFrame(
            registryId: 303,
            touches: Array(repeating: (x: 0.5, y: 0.5), count: 2),
            timestamp: 100.03
        )
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0, senderId: 0x638))
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.lockedGestureContext?.contactSession?.senderId, 0x638)
        await drainMultitouchTasks()
    }

    func testSyntheticRestartPreservesConsumptionAcrossTimestampGaps() async throws {
        for gap in [0.01, 0.2, 20.0] {
            let fixture = try makeFixture()
            let harness = await installRecoveringMultitouchSource(fixture)
            let contacts = Array(repeating: (x: Float(0.5), y: Float(0.2)), count: 3)
            harness.backend.emitFrame(registryId: 303, touches: contacts, timestamp: 100)
            XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
            harness.backend.emitFrame(registryId: 303, touches: contacts, timestamp: 100 + gap)
            XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
            harness.backend.emitFrame(registryId: 303, touches: [], timestamp: 100 + gap + 0.01)
            XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
            await cleanupRecoveringMultitouchSource(fixture, harness: harness)
        }
    }

    private func driveCommittedPartialLift(_ fixture: Fixture) -> TimeInterval {
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: time)
        time += 0.01
        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.24, at: time)
        for _ in 0 ..< 12 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.24, at: time)
        }
        time += 0.01
        sendFrame(fixture, phase: .changed, fingers: 2, x: 0.5, y: 0.24, at: time)
        return time
    }

    private func scrollVerdict(
        _ fixture: Fixture,
        momentumPhase: UInt32,
        phase: UInt32,
        senderId: UInt64? = 0x637,
        isContinuous: Bool = true
    ) -> Bool {
        fixture.controller.mouseEventHandler.receiveTapScrollWheel(MouseScrollIntake(
            location: CGPoint(x: 800, y: 450),
            deltaX: 0,
            deltaY: 8,
            momentumPhase: momentumPhase,
            phase: phase,
            modifiersRawValue: 0,
            isContinuous: isContinuous,
            senderId: senderId
        ))
    }

    func testScrollTraceExplainsSuppressionAndReleasedContactOwnership() throws {
        let fixture = try makeFixture()
        let recorder = TrackpadScrollTrace.shared
        recorder.beginCapture()
        defer {
            recorder.endCapture()
            recorder.releaseStorage()
        }

        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: 100)
        try assertTracedScroll(fixture, phase: CGScrollPhase.changed.rawValue, decision: .activeGesture)
        try assertTracedScroll(fixture, decision: .ownedSession)
        sendFrame(fixture, phase: .changed, fingers: 3, x: 0.5, y: 0.24, at: 100.01)
        sendFrame(fixture, phase: .changed, fingers: 2, x: 0.5, y: 0.24, at: 100.02)
        try assertTracedScroll(fixture, phase: CGScrollPhase.changed.rawValue, decision: .liftLatch)

        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: 100.03)
        let released = try assertTracedScroll(fixture, decision: .ownedSession)
        XCTAssertTrue(released.contains("retained=1:0:1:1591 retainedCurrent=1"))
        try assertTracedScroll(fixture, phase: CGScrollPhase.ended.rawValue, decision: .terminalTail)
        try assertTracedScroll(fixture, phase: CGScrollPhase.cancelled.rawValue, decision: .terminalTail)
        try assertTracedScroll(fixture, momentumPhase: 2, decision: .momentumTail)

        let freshPhase = try assertTracedScroll(
            fixture, phase: CGScrollPhase.began.rawValue, decision: .freshPhase
        )
        let states = freshPhase.components(separatedBy: " after={")
        XCTAssertEqual(states.count, 2)
        XCTAssertTrue(states.first?.contains("suppressMomentum=true") == true)
        XCTAssertTrue(states.last?.contains("suppressMomentum=false") == true)
        try assertTracedScroll(fixture, phase: CGScrollPhase.changed.rawValue, decision: .trackpadUnclaimed)
        try assertTracedScroll(fixture, senderId: nil, decision: .wheelDisabled)
        try assertTracedScroll(fixture, senderId: 0x638, decision: .wheelDisabled)

        sendFrame(fixture, phase: .began, fingers: 2, x: 0.5, y: 0.5, at: 101)
        let freshContact = try assertTracedScroll(fixture, decision: .wheelDisabled)
        XCTAssertTrue(freshContact.contains("retained=none retainedCurrent=none"))
        let trace = recorder.dump()
        let retained = try XCTUnwrap(trace.range(of: "ownership action=retain contact=1:0:1:1591"))
        let releasedGesture = try XCTUnwrap(trace.range(of: "gesture timestamp=100.03"))
        let retired = try XCTUnwrap(trace.range(
            of: "ownership action=retire contact=1:0:1:1591 generation=1 currentSession=2"
        ))
        let freshGesture = try XCTUnwrap(trace.range(of: "gesture timestamp=101.0"))
        XCTAssertLessThan(retained.lowerBound, releasedGesture.lowerBound)
        XCTAssertLessThan(releasedGesture.lowerBound, retired.lowerBound)
        XCTAssertLessThan(retired.lowerBound, freshGesture.lowerBound)
    }

    func testScrollTraceReportsWheelBindingAndInputSuppressionReturns() throws {
        let fixture = try makeFixture(scrollGestureEnabled: true)
        let recorder = TrackpadScrollTrace.shared
        recorder.beginCapture()
        defer {
            recorder.endCapture()
            recorder.releaseStorage()
        }
        let requiredModifiers = fixture.controller.settings.gestures.scrollModifierKey.cgEventFlag.rawValue
        try assertTracedScroll(
            fixture, modifiersRawValue: requiredModifiers, isContinuous: false, decision: .wheelBinding
        )
        try assertTracedScroll(
            fixture, modifiersRawValue: requiredModifiers ^ CGEventFlags.maskShift.rawValue,
            isContinuous: false, decision: .modifierMismatch
        )
        fixture.controller.isLockScreenActive = true
        try assertTracedScroll(fixture, phase: CGScrollPhase.changed.rawValue, decision: .inputSuppressed)
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.5, y: 0.2, at: 100)
        let gesture = try XCTUnwrap(recorder.dump().split(separator: "\n").last)
        XCTAssertTrue(gesture.contains("gesture timestamp=100.0"))
        XCTAssertTrue(gesture.contains("processed=false"))
    }

    @discardableResult
    private func assertTracedScroll(
        _ fixture: Fixture,
        momentumPhase: UInt32 = 0,
        phase: UInt32 = 0,
        senderId: UInt64? = 0x637,
        modifiersRawValue: UInt64 = 0,
        isContinuous: Bool = true,
        decision: MouseEventHandler.ScrollDecision,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let suppressed = fixture.controller.mouseEventHandler.receiveTapScrollWheel(MouseScrollIntake(
            location: CGPoint(x: 800, y: 450), deltaX: 0, deltaY: 8,
            momentumPhase: momentumPhase, phase: phase, modifiersRawValue: modifiersRawValue,
            isContinuous: isContinuous, senderId: senderId
        ))
        XCTAssertEqual(suppressed, decision.suppresses, file: file, line: line)
        let record = try XCTUnwrap(
            TrackpadScrollTrace.shared.dump().split(separator: "\n").last,
            file: file, line: line
        )
        XCTAssertTrue(record.contains(" scroll "), file: file, line: line)
        XCTAssertTrue(
            record.contains("suppressed=\(suppressed) reason=\(decision.rawValue)"),
            file: file, line: line
        )
        return String(record)
    }

    func testCommittedPartialLiftLatchesAndBlocksChainedGesture() throws {
        let fixture = try makeFixture(
            workspaceFingers: .three,
            scrollGestureEnabled: true,
            columnFingers: .two
        )
        var time = driveCommittedPartialLift(fixture)

        let handler = fixture.controller.mouseEventHandler
        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertTrue(handler.state.suppressGestureStartUntilAllTouchesLift)
        XCTAssertTrue(handler.state.consumeTrackpadScrollUntilAllTouchesLift)
        XCTAssertTrue(handler.state.suppressTrackpadMomentumScroll)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)

        for step in 1 ... 6 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 2, x: 0.5 + 0.03 * CGFloat(step), y: 0.24, at: time)
        }
        XCTAssertEqual(handler.state.gesturePhase, .idle)

        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertFalse(handler.state.suppressGestureStartUntilAllTouchesLift)
        XCTAssertFalse(handler.state.consumeTrackpadScrollUntilAllTouchesLift)
    }

    func testCommittedPartialLiftConsumesScrollAndMomentumTail() throws {
        let fixture = try makeFixture(
            workspaceFingers: .three,
            scrollGestureEnabled: true,
            columnFingers: .two
        )
        var time = driveCommittedPartialLift(fixture)
        let handler = fixture.controller.mouseEventHandler

        fixture.controller.isEnabled = false

        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.changed.rawValue))
        XCTAssertTrue(handler.state.suppressTrackpadMomentumScroll)

        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertFalse(handler.state.consumeTrackpadScrollUntilAllTouchesLift)

        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.ended.rawValue))
        XCTAssertTrue(handler.state.suppressTrackpadMomentumScroll)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 1, phase: 0))
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.mayBegin.rawValue))
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 2, phase: 0))
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.changed.rawValue))
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 3, phase: 0))
        XCTAssertTrue(handler.state.suppressTrackpadMomentumScroll)
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.began.rawValue))
        XCTAssertFalse(handler.state.suppressTrackpadMomentumScroll)
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: CGScrollPhase.changed.rawValue))
    }

    func testCursorMonitorSwipeSwitchesThatMonitorOnly() throws {
        let fixture = try makeFixture()
        let secondary = try configureSecondMonitor(fixture)
        let monitorB = secondary.monitor
        let wsB1 = try XCTUnwrap(secondary.workspaceIds.first)
        let wsB2 = try XCTUnwrap(secondary.workspaceIds.last)
        let manager = fixture.controller.workspaceManager
        XCTAssertTrue(manager.setActiveWorkspace(wsB1, on: monitorB.id))
        XCTAssertTrue(manager.setActiveWorkspace(fixture.ws1, on: fixture.monitor.id))

        _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100, location: CGPoint(x: 2400, y: 450))

        XCTAssertEqual(manager.activeWorkspaceOrFirst(on: monitorB.id)?.id, wsB2)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
        XCTAssertEqual(manager.interactionMonitorId, monitorB.id)
    }

    func testDwindleWorkspaceSwipeSwitchesWorkspaces() throws {
        let fixture = try makeFixture(enableNiri: false)
        fixture.controller.settings.workspaces.configurations = fixture.controller.settings.workspaces.configurations
            .map {
                $0.with(layoutType: .dwindle)
            }
        fixture.controller.enableDwindleLayout()

        _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100)

        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
        XCTAssertEqual(fixture.controller.workspaceManager.activeLayoutKind(for: fixture.ws2), .dwindle)
    }

    func testSingleWorkspaceCursorMonitorSwipeDoesNotMutateInteraction() throws {
        let fixture = try makeFixture()
        let secondary = try configureSecondMonitor(fixture, workspaceNames: ["6"])
        let workspaceId = try XCTUnwrap(secondary.workspaceIds.first)
        let manager = fixture.controller.workspaceManager
        XCTAssertTrue(manager.setActiveWorkspace(workspaceId, on: secondary.monitor.id))
        XCTAssertTrue(manager.setActiveWorkspace(fixture.ws1, on: fixture.monitor.id))
        let interactionBefore = manager.interactionMonitorId

        _ = performVerticalSwipe(
            fixture,
            totalUnits: 220,
            startTime: 100,
            location: CGPoint(x: 2400, y: 450)
        )

        XCTAssertEqual(manager.activeWorkspaceOrFirst(on: secondary.monitor.id)?.id, workspaceId)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
        XCTAssertEqual(manager.interactionMonitorId, interactionBefore)
    }

    func testCommandHandlerRelativeSwitchUsesInteractionMonitor() throws {
        let fixture = try makeFixture()
        let secondary = try configureSecondMonitor(fixture)
        let wsB1 = try XCTUnwrap(secondary.workspaceIds.first)
        let wsB2 = try XCTUnwrap(secondary.workspaceIds.last)
        let manager = fixture.controller.workspaceManager
        XCTAssertTrue(manager.setActiveWorkspace(fixture.ws1, on: fixture.monitor.id))
        XCTAssertTrue(manager.setActiveWorkspace(wsB1, on: secondary.monitor.id))

        XCTAssertEqual(
            fixture.controller.commandHandler.performCommand(.workspace(.next)),
            .executed
        )

        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
        XCTAssertEqual(manager.activeWorkspaceOrFirst(on: secondary.monitor.id)?.id, wsB2)
        XCTAssertEqual(manager.interactionMonitorId, secondary.monitor.id)
    }

    func testCollidingConfigForcesVerticalAndPreservesStoredAxis() throws {
        let fixture = try makeFixture(workspaceAxis: .horizontal, scrollGestureEnabled: true)
        XCTAssertTrue(fixture.controller.settings.gestures.workspaceSwipeAxisLockedToVertical)
        XCTAssertEqual(fixture.controller.settings.gestures.effectiveWorkspaceSwipeAxis, .vertical)
        _ = performVerticalSwipe(fixture, totalUnits: 220, startTime: 100)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
        XCTAssertEqual(fixture.controller.settings.gestures.workspaceSwipeAxis, .horizontal)
    }

    func testColumnOnlyConfigDoesNotArmWithoutColumnContext() throws {
        let fixture = try makeFixture(
            workspaceSwipeEnabled: false,
            scrollGestureEnabled: true,
            enableNiri: false
        )
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 3, x: 0.2, y: 0.5, at: time)
        for step in 1 ... 4 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 3, x: 0.2 + 0.05 * CGFloat(step), y: 0.5, at: time)
        }
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertFalse(fixture.controller.mouseEventHandler.isTrackpadSwipeSessionActive)
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
    }

    func testHorizontalAxisSwipeWithDistinctCountsSwitches() throws {
        let fixture = try makeFixture(
            workspaceFingers: .four,
            workspaceAxis: .horizontal,
            scrollGestureEnabled: true,
            columnFingers: .three
        )
        var time: TimeInterval = 100
        sendFrame(fixture, phase: .began, fingers: 4, x: 0.8, y: 0.5, at: time)
        for step in 1 ... 8 {
            time += 0.01
            sendFrame(fixture, phase: .changed, fingers: 4, x: 0.8 - 0.055 * CGFloat(step), y: 0.5, at: time)
        }
        time += 0.01
        sendFrame(fixture, phase: .ended, fingers: 0, x: 0, y: 0, at: time)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
    }

    func testWorkspaceGestureRecoversThroughRawSourceReplacementWithoutRestart() async throws {
        let fixture = try makeFixture()
        let harness = await installRecoveringMultitouchSource(fixture)
        let firstGeneration = try XCTUnwrap(harness.source.diagnosticsSnapshot().activeGeneration)
        let location = CGPoint(x: 800, y: 450)

        sendRawFrame(
            harness.source,
            generation: firstGeneration,
            fingers: 3,
            x: 0.5,
            y: 0.2,
            at: 100,
            location: location
        )
        sendRawFrame(
            harness.source,
            generation: firstGeneration,
            fingers: 3,
            x: 0.5,
            y: 0.24,
            at: 100.01,
            location: location
        )
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .committed)
        fixture.controller.mouseEventHandler.state.suppressGestureStartUntilAllTouchesLift = true
        fixture.controller.mouseEventHandler.state.consumeTrackpadScrollUntilAllTouchesLift = true
        fixture.controller.mouseEventHandler.state.suppressTrackpadMomentumScroll = true

        harness.source.requestRevalidation(.wake)
        await drainMultitouchTasks()
        harness.sleeper.resumeNext()
        await drainMultitouchTasks()
        let recoveredGeneration = try XCTUnwrap(harness.source.diagnosticsSnapshot().activeGeneration)

        XCTAssertNotEqual(recoveredGeneration, firstGeneration)
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertFalse(fixture.controller.mouseEventHandler.state.suppressGestureStartUntilAllTouchesLift)
        XCTAssertFalse(fixture.controller.mouseEventHandler.state.consumeTrackpadScrollUntilAllTouchesLift)
        XCTAssertFalse(fixture.controller.mouseEventHandler.state.suppressTrackpadMomentumScroll)

        var timestamp = 101.0
        sendRawFrame(
            harness.source,
            generation: recoveredGeneration,
            fingers: 3,
            x: 0.5,
            y: 0.2,
            at: timestamp,
            location: location
        )
        for step in 1 ... 8 {
            timestamp += 0.01
            sendRawFrame(
                harness.source,
                generation: recoveredGeneration,
                fingers: 3,
                x: 0.5,
                y: 0.2 + 0.055 * CGFloat(step),
                at: timestamp,
                location: location
            )
        }
        timestamp += 0.01
        sendRawFrame(
            harness.source,
            generation: recoveredGeneration,
            fingers: 0,
            x: 0,
            y: 0,
            at: timestamp,
            location: location
        )

        XCTAssertEqual(activeWorkspace(fixture), fixture.ws2)
        XCTAssertTrue(fixture.controller.mouseEventHandler.multitouchDiagnosticsSnapshot?.state == .running)
        await cleanupRecoveringMultitouchSource(fixture, harness: harness)
    }

    func testColumnGestureRecoversThroughRawSourceReplacementWithoutRestart() async throws {
        let fixture = try makeFixture(scrollGestureEnabled: true)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        for index in 0 ..< 3 {
            let token = addManagedWindow(
                to: fixture.ws1,
                controller: fixture.controller,
                pid: pid_t(8_001 + index),
                windowId: 8_101 + index
            )
            _ = engine.addWindow(token: token, to: fixture.ws1, afterSelection: nil)
        }
        for column in engine.columns(in: fixture.ws1) {
            column.cachedWidth = 700
        }

        let harness = await installRecoveringMultitouchSource(fixture)
        let firstGeneration = try XCTUnwrap(harness.source.diagnosticsSnapshot().activeGeneration)
        let location = CGPoint(x: 800, y: 450)
        sendRawFrame(
            harness.source,
            generation: firstGeneration,
            fingers: 3,
            x: 0.8,
            y: 0.5,
            at: 200,
            location: location
        )
        sendRawFrame(
            harness.source,
            generation: firstGeneration,
            fingers: 3,
            x: 0.74,
            y: 0.5,
            at: 200.01,
            location: location
        )
        XCTAssertTrue(fixture.controller.workspaceManager.animationDriver.hasGesture(in: fixture.ws1))
        fixture.controller.mouseEventHandler.state.suppressGestureStartUntilAllTouchesLift = true
        fixture.controller.mouseEventHandler.state.consumeTrackpadScrollUntilAllTouchesLift = true
        fixture.controller.mouseEventHandler.state.suppressTrackpadMomentumScroll = true

        harness.source.requestRevalidation(.wake)
        await drainMultitouchTasks()
        harness.sleeper.resumeNext()
        await drainMultitouchTasks()
        let recoveredGeneration = try XCTUnwrap(harness.source.diagnosticsSnapshot().activeGeneration)

        XCTAssertNotEqual(recoveredGeneration, firstGeneration)
        XCTAssertFalse(fixture.controller.workspaceManager.animationDriver.hasGesture(in: fixture.ws1))
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertFalse(fixture.controller.mouseEventHandler.state.suppressGestureStartUntilAllTouchesLift)
        XCTAssertFalse(fixture.controller.mouseEventHandler.state.consumeTrackpadScrollUntilAllTouchesLift)
        XCTAssertFalse(fixture.controller.mouseEventHandler.state.suppressTrackpadMomentumScroll)

        var timestamp = 201.0
        sendRawFrame(
            harness.source,
            generation: recoveredGeneration,
            fingers: 3,
            x: 0.8,
            y: 0.5,
            at: timestamp,
            location: location
        )
        for step in 1 ... 4 {
            timestamp += 0.01
            sendRawFrame(
                harness.source,
                generation: recoveredGeneration,
                fingers: 3,
                x: 0.8 - 0.03 * CGFloat(step),
                y: 0.5,
                at: timestamp,
                location: location
            )
        }
        XCTAssertTrue(fixture.controller.workspaceManager.animationDriver.hasGesture(in: fixture.ws1))
        timestamp += 0.01
        sendRawFrame(
            harness.source,
            generation: recoveredGeneration,
            fingers: 0,
            x: 0,
            y: 0,
            at: timestamp,
            location: location
        )

        XCTAssertFalse(fixture.controller.workspaceManager.animationDriver.hasGesture(in: fixture.ws1))
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)
        await cleanupRecoveringMultitouchSource(fixture, harness: harness)
    }

    func testCancelledPhaseSettlesCommittedGestureWithoutFlick() async throws {
        let fixture = try makeFixture(scrollGestureEnabled: true)
        let engine = try XCTUnwrap(fixture.controller.niriEngine)
        for index in 0 ..< 3 {
            let token = addManagedWindow(
                to: fixture.ws1,
                controller: fixture.controller,
                pid: pid_t(8_201 + index),
                windowId: 8_301 + index
            )
            _ = engine.addWindow(token: token, to: fixture.ws1, afterSelection: nil)
        }
        for column in engine.columns(in: fixture.ws1) {
            column.cachedWidth = 700
        }

        let harness = await installRecoveringMultitouchSource(fixture)
        let generation = try XCTUnwrap(harness.source.diagnosticsSnapshot().activeGeneration)
        let location = CGPoint(x: 800, y: 450)
        sendRawFrame(harness.source, generation: generation, fingers: 3, x: 0.8, y: 0.5, at: 300, location: location)
        sendRawFrame(
            harness.source,
            generation: generation,
            fingers: 3,
            x: 0.74,
            y: 0.5,
            at: 300.01,
            location: location
        )
        XCTAssertTrue(fixture.controller.workspaceManager.animationDriver.hasGesture(in: fixture.ws1))

        fixture.controller.mouseEventHandler.receiveTapGestureEvent(
            MouseEventHandler.GestureEventSnapshot(
                location: location,
                phaseRawValue: NSEvent.Phase.cancelled.rawValue,
                timestamp: 300.02,
                touches: []
            )
        )

        XCTAssertFalse(fixture.controller.workspaceManager.animationDriver.hasGesture(in: fixture.ws1))
        XCTAssertEqual(fixture.controller.mouseEventHandler.state.gesturePhase, .idle)
        XCTAssertEqual(activeWorkspace(fixture), fixture.ws1)

        sendRawFrame(harness.source, generation: generation, fingers: 0, x: 0, y: 0, at: 300.5, location: location)
        sendRawFrame(harness.source, generation: generation, fingers: 3, x: 0.8, y: 0.5, at: 301, location: location)
        sendRawFrame(
            harness.source,
            generation: generation,
            fingers: 3,
            x: 0.74,
            y: 0.5,
            at: 301.01,
            location: location
        )
        XCTAssertTrue(fixture.controller.workspaceManager.animationDriver.hasGesture(in: fixture.ws1))
        await cleanupRecoveringMultitouchSource(fixture, harness: harness)
    }

    private func installRecoveringMultitouchSource(
        _ fixture: Fixture,
        includeSecondDevice: Bool = false
    ) async -> (
        source: MultitouchGestureSource,
        backend: FakeMultitouchBackend,
        sleeper: ManualMultitouchSleeper
    ) {
        let device = FakeMultitouchBackend.device(pointer: 0xC1, registryId: 303, senderId: 0x637)
        let backend = FakeMultitouchBackend()
        let registeredDevices = includeSecondDevice
            ? [device, FakeMultitouchBackend.device(pointer: 0xC2, registryId: 304, senderId: 0x638)]
            : [device]
        backend.enumerations = [
            FakeMultitouchBackend.enumeration(registeredDevices),
            FakeMultitouchBackend.enumeration(registeredDevices)
        ]
        let sleeper = ManualMultitouchSleeper()
        let source = MultitouchGestureSource(
            operations: backend.operations(sleeper: sleeper),
            topologyMonitoringEnabled: false
        )
        fixture.controller.mouseEventHandler.installMultitouchSource(source)
        await drainMultitouchTasks()
        XCTAssertEqual(sleeper.pendingCount, 1)
        sleeper.resumeNext()
        await drainMultitouchTasks()
        XCTAssertEqual(source.diagnosticsSnapshot().state, .running)
        return (source, backend, sleeper)
    }

    private func cleanupRecoveringMultitouchSource(
        _ fixture: Fixture,
        harness: (
            source: MultitouchGestureSource,
            backend: FakeMultitouchBackend,
            sleeper: ManualMultitouchSleeper
        )
    ) async {
        fixture.controller.mouseEventHandler.cleanup()
        harness.sleeper.resumeAll()
        await drainMultitouchTasks()
    }

    func testCommittedVisibilityAbortRetainsPhaseLessTailUntilFreshContact() async throws {
        let fixture = try makeFixture()
        let harness = await installRecoveringMultitouchSource(fixture)
        let controller = fixture.controller
        let handler = controller.mouseEventHandler
        defer {
            controller.eventIntake.close()
            handler.cleanup()
            harness.sleeper.resumeAll()
        }
        harness.backend.emitFrame(
            registryId: 303,
            touches: Array(repeating: (x: Float(0.5), y: Float(0.2)), count: 3),
            timestamp: 100
        )
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        harness.backend.emitFrame(
            registryId: 303,
            touches: Array(repeating: (x: Float(0.5), y: Float(0.24)), count: 3),
            timestamp: 100.01
        )
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        XCTAssertEqual(handler.state.gesturePhase, .committed)
        XCTAssertTrue(handler.state.consumedTrackpadSessions.isEmpty)
        controller.eventIntake.open(sink: controller.eventInterpreter)
        controller.eventIntake.beginPerformanceCapture()

        handler.handleAppVisibilityChanged()

        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        XCTAssertEqual(controller.eventIntake.performanceSnapshot()?.acceptedEvents, 0)
        harness.backend.emitFrame(registryId: 303, touches: [], timestamp: 100.02)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        XCTAssertEqual(controller.eventIntake.performanceSnapshot()?.acceptedEvents, 0)
        harness.backend.emitFrame(
            registryId: 303,
            touches: Array(repeating: (x: Float(0.5), y: Float(0.5)), count: 2),
            timestamp: 100.03
        )
        XCTAssertFalse(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        XCTAssertEqual(controller.eventIntake.performanceSnapshot()?.acceptedEvents, 1)
    }

    func testViewportTerminationRetainsPhaseLessTailWithoutTerminalFrame() async throws {
        let fixture = try makeFixture(workspaceSwipeEnabled: false, scrollGestureEnabled: true)
        try addColumnGestureWindows(to: fixture)
        let harness = await installRecoveringMultitouchSource(fixture)
        let controller = fixture.controller
        let handler = controller.mouseEventHandler
        defer {
            controller.eventIntake.close()
            handler.cleanup()
            harness.sleeper.resumeAll()
        }
        for step in 0 ... 4 {
            harness.backend.emitFrame(
                registryId: 303,
                touches: Array(repeating: (x: Float(0.8) - Float(step) * 0.03, y: Float(0.5)), count: 3),
                timestamp: 100 + Double(step) * 0.01
            )
            XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        }
        XCTAssertEqual(handler.state.gesturePhase, .committed)
        XCTAssertEqual(handler.state.activeGestureMode, .columnScroll)
        XCTAssertTrue(handler.state.consumedTrackpadSessions.isEmpty)
        let sessionID = try XCTUnwrap(controller.workspaceManager.animationDriver.gestureSessionID(in: fixture.ws1))
        XCTAssertEqual(handler.state.viewportGestureSessionID, sessionID)
        controller.eventIntake.open(sink: controller.eventInterpreter)
        controller.eventIntake.beginPerformanceCapture()

        XCTAssertTrue(handler.terminateViewportGesture(
            in: fixture.ws1,
            sessionID: sessionID,
            disposition: .settleLiveOffsetWithoutRelayout
        ))

        XCTAssertEqual(handler.state.gesturePhase, .idle)
        XCTAssertNil(handler.state.lockedGestureContext)
        XCTAssertTrue(scrollVerdict(fixture, momentumPhase: 0, phase: 0))
        XCTAssertEqual(controller.eventIntake.performanceSnapshot()?.acceptedEvents, 0)
    }

    private func sendRawFrame(
        _ source: MultitouchGestureSource,
        generation: UInt,
        fingers: Int,
        x: CGFloat,
        y: CGFloat,
        at timestamp: TimeInterval,
        location: CGPoint
    ) {
        source.handleRawFrame(
            MultitouchGestureSource.RawFrame(
                touches: (0 ..< fingers).map { _ in
                    MultitouchGestureSource.RawTouch(x: Float(x), y: Float(y))
                },
                timestamp: timestamp
            ),
            generation: generation,
            location: location
        )
    }
}
