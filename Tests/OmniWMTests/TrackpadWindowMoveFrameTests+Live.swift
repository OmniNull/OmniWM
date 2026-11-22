// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

extension TrackpadWindowMoveFrameTests {
    func testMoveUsesOnlyItsOwnSpeedForAnInteriorStrokeAndReturnsToTheGrab() throws {
        let speeds: [(move: CGFloat, resize: Double)] = [(2, 1), (2, 2), (1, 2)]
        let fullResizeStroke: CGFloat = 1 / 8
        let moveStroke = fullResizeStroke / 2
        for kind in MoveKind.allCases {
            for speed in speeds {
                let fixture = try makeMoveFixture(kind, moveSpeed: speed.move)
                fixture.controller.settings.gestures.windowResizeSensitivity = speed.resize
                let beginTime = fixture.events.begin.timestamp
                fixture.handler.liveDragClock = { beginTime }
                let display = fixture.monitor.frame
                let destination = fixture.startFrame.offsetBy(
                    dx: display.width * moveStroke * speed.move, dy: display.height * moveStroke * speed.move
                )
                XCTAssertTrue(display.contains(destination.center))
                let touch = CGPoint(x: fixture.startTouch.x + moveStroke, y: fixture.startTouch.y + moveStroke)

                fixture.begin()
                fixture.send(fixture.event(at: touch))
                XCTAssertTrue(fixture.handler.state.gestureOwnsWindowInteraction)
                XCTAssertEqual(
                    try fixture.projection().frameChanges.first { $0.token == fixture.moved }?.frame,
                    destination
                )
                let context = try XCTUnwrap(fixture.handler.state.lockedGestureContext)
                XCTAssertEqual(fixture.handler.gestureWindowLocation(for: context), destination.center)

                fixture.send(fixture.event(at: fixture.startTouch))
                XCTAssertEqual(
                    try fixture.projection().frameChanges.first { $0.token == fixture.moved }?.frame,
                    fixture.startFrame
                )
                fixture.release()
                XCTAssertFalse(fixture.handler.state.isMoving)
                XCTAssertEqual(fixture.order(), [[fixture.moved], [fixture.target]])
            }
        }
    }

    func testOffCentreTrackpadGrabAimsWithTheWindowMidpointOnBothStripAxes() throws {
        for kind in [MoveKind.horizontal, .vertical] {
            let fixture = try makeMoveFixture(kind)
            let start = fixture.startFrame
            let grab = kind == .horizontal
                ? CGPoint(x: start.minX + start.width / 8, y: start.midY)
                : CGPoint(x: start.midX, y: start.minY + start.height / 8)
            let target = fixture.targetFrame
            let point = CGPoint(x: grab.x + target.midX - start.midX, y: grab.y + target.midY - start.midY)
            fixture.handler.liveDragClock = { 0 }
            fixture.send(Fixture.event(location: grab, touch: fixture.startTouch, phase: .began, sample: 0))
            fixture.send(Fixture.event(
                location: grab, touch: fixture.touch(at: point, grabbedAt: grab), phase: .changed, sample: 1
            ))

            let context = try XCTUnwrap(fixture.handler.liveColumnContext(for: fixture.workspace))
            let virtual = try XCTUnwrap(fixture.handler.livePointer.location)
            let carried = try XCTUnwrap(fixture.base.niri.liveColumnMove?.floatingFrame)
            let aimed = fixture.handler.liveDragReference(virtual, orientation: context.orientation)
            XCTAssertEqual(carried.center, target.center)
            XCTAssertEqual(context.primaryCoordinate(of: aimed), context.primaryCoordinate(of: target.center))
            XCTAssertNotEqual(context.primaryCoordinate(of: virtual), context.primaryCoordinate(of: target.center))

            let dwell = fixture.base.niri.liveCentreStackDelay
            fixture.handler.liveDragClock = { dwell }
            try XCTUnwrap(fixture.handler.liveDragSession?.hoverTimer).fire()
            XCTAssertEqual(
                fixture.base.niri.liveColumnMove?.landing?.targetWindowId,
                fixture.base.niriNode(fixture.target)?.id
            )
            fixture.cancel()
        }
    }

    func testANeighbourPresentsAnIntermediateFrameWhileTheFingersAreDown() throws {
        let fixture = try makeMoveFixture(.horizontal, windows: 3)
        fixture.controller.motionPolicy.animationsEnabled = true
        fixture.handler.liveDragClock = { 0 }
        fixture.begin()
        let farSide = CGPoint(x: fixture.targetFrame.maxX - fixture.targetFrame.width / 8, y: fixture.targetFrame.midY)
        fixture.send(fixture.event(at: fixture.touch(at: farSide)))
        let dwell = fixture.base.niri.liveHoverDelay
        fixture.handler.liveDragClock = { dwell }
        fixture.handler.liveDragSession?.hoverTimer?.fire()

        let neighbour = try XCTUnwrap(fixture.base.niriNode(fixture.tokens[2]))
        let column = try XCTUnwrap(fixture.base.niri.findColumn(containing: neighbour, in: fixture.workspace))
        let spring = try XCTUnwrap(column.moveAnimation?.animation)
        let display = fixture.monitor.displayId
        let handler = fixture.controller.niriLayoutHandler
        XCTAssertTrue(handler.hasScrollAnimation(for: fixture.workspace))
        handler.tickScrollAnimation(targetTime: spring.startTime, displayId: display)
        let first = try XCTUnwrap(neighbour.renderedFrame).midX
        let nextFrame = min(spring.duration / 2, 1 / fixture.base.niri.displayRefreshRate(in: fixture.workspace))
        handler.tickScrollAnimation(targetTime: spring.startTime + nextFrame, displayId: display)
        let during = try XCTUnwrap(neighbour.renderedFrame).midX
        handler.tickScrollAnimation(targetTime: (spring.startTime + spring.duration).nextUp, displayId: display)
        let last = try XCTUnwrap(neighbour.renderedFrame).midX

        XCTAssertGreaterThan(during, min(first, last))
        XCTAssertLessThan(during, max(first, last))
        XCTAssertTrue(fixture.handler.state.gestureOwnsWindowInteraction)
        fixture.release()
        XCTAssertEqual(fixture.order(), [[fixture.target], [fixture.moved], [fixture.tokens[2]]])
    }

    func testTrackpadLiftSettlesFromTheLastCarriedFrameOnBothStripAxes() throws {
        for kind in [MoveKind.horizontal, .vertical] {
            let fixture = try makeMoveFixture(kind)
            fixture.controller.motionPolicy.animationsEnabled = true
            let touch = fixture.slideWithinStartingWindow(1 / 4)
            let release = fixture.expectedFloatingFrame(at: touch)
            fixture.begin()
            fixture.send(fixture.event(at: touch))
            XCTAssertEqual(fixture.base.niri.liveColumnMove?.floatingFrame, release)

            fixture.send(fixture.event(at: touch, phase: .ended, sample: 3))

            let window = try XCTUnwrap(fixture.base.niriNode(fixture.moved))
            let motion = try XCTUnwrap(kind == .horizontal ? window.moveYAnimation : window.moveXAnimation)
            let offset = kind == .horizontal
                ? release.minY - fixture.startFrame.minY
                : release.minX - fixture.startFrame.minX
            XCTAssertNotEqual(offset, 0)
            XCTAssertEqual(motion.fromOffset, offset)
            XCTAssertFalse(fixture.handler.state.gestureOwnsWindowInteraction)
        }
    }

    func testRetiringTheCarriedWindowCancelsTheGestureAndDiscardsItsUndoStart() throws {
        let fixture = try makeMoveFixture(.horizontal)
        fixture.begin()
        fixture.move()
        XCTAssertTrue(fixture.handler.state.gestureOwnsWindowInteraction)
        let before = try XCTUnwrap(fixture.base.manager.entry(for: fixture.moved))

        fixture.controller.axEventHandler.retireManagedWindow(before, reason: .authoritativeRescan)

        XCTAssertNil(fixture.base.manager.entry(for: fixture.moved))
        XCTAssertNil(fixture.base.niri.liveColumnMove)
        XCTAssertNil(fixture.handler.liveDragSession)
        XCTAssertNil(fixture.handler.state.liveDragLayoutStart)
        XCTAssertFalse(fixture.handler.state.gestureOwnsWindowInteraction)
        fixture.release()
        XCTAssertEqual(fixture.handler.tapInputs.gesturePhase, .idle)
        XCTAssertFalse(fixture.controller.niriLayoutHandler.stepLayoutHistory(.undo, in: fixture.workspace))
    }

    func testVirtualEdgeDwellAdvancesTheLandingWithoutAHoldOnThePhysicalPointer() throws {
        let fixture = try makeMoveFixture(
            .horizontal,
            windows: Self.windowsWithAnOffscreenColumn,
            adjacentDisplay: true
        )
        let handler = fixture.handler
        let source = fixture.monitor.frame
        let other = fixture.base.monitors[1]
        let beyondEdge = CGPoint(x: other.frame.midX, y: fixture.startFrame.midY)
        handler.liveDragClock = { 0 }
        let original = fixture.order()

        fixture.begin()
        fixture.send(fixture.event(at: fixture.touch(at: beyondEdge)))
        let virtual = try XCTUnwrap(handler.livePointer.location)
        XCTAssertTrue(source.contains(virtual))
        XCTAssertEqual(handler.liveDragSession?.edgeScroll?.edge, .trailing)
        XCTAssertNil(fixture.controller.pointerEdgeBarrier.liveDragHold)
        let previousSlot = fixture.base.niri.liveColumnMove?.dropSpaceId
        handler.liveDragClock = { MoveConfiguration.liveEdgeScrollDelay }
        try XCTUnwrap(handler.liveDragSession?.edgeScroll?.delayTimer).fire()
        let move = try XCTUnwrap(fixture.base.niri.liveColumnMove)
        XCTAssertEqual(move.workspaceId, fixture.workspace)
        XCTAssertEqual(handler.liveDragSession?.edgeScroll?.hopping, true)
        XCTAssertNotEqual(move.dropSpaceId, previousSlot)
        XCTAssertNil(fixture.controller.pointerEdgeBarrier.liveDragHold)
        fixture.cancel()
        XCTAssertEqual(fixture.order(), original)
        XCTAssertNil(handler.liveDragSession)
    }
}
