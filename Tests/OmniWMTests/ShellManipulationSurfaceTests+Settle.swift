// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
extension ShellManipulationSurfaceTests {
    private static let scaled = CGRect(x: 80.0, y: 70.0, width: 100.0 * 13 / 18, height: 80.0 * 13 / 18)

    private func dragScale(_ fixture: Fixture) {
        fixture.surface.press(at: CGPoint(x: 175, y: 145), timestamp: 0)
        fixture.surface.drag(to: CGPoint(x: 145, y: 125), screen: .zero, timestamp: 0.01)
    }

    private func assertScaledHits(_ fixture: Fixture, line: UInt = #line) throws {
        let surface = fixture.surface
        let move = surface.element(at: CGPoint(x: 85, y: 75)) { $0.acceptsPointer }
        XCTAssertEqual(surface.manipulationOwner(of: move), try fixture.target(), line: line)
        XCTAssertEqual(surface.element(at: CGPoint(x: 150, y: 75)) { $0.acceptsPointer }, move, line: line)
        XCTAssertNotEqual(surface.element(at: CGPoint(x: 160, y: 75)) { $0.acceptsPointer }, move, line: line)
        let input = surface.element(at: CGPoint(x: 85, y: 93)) { $0.acceptsPointer }
        XCTAssertNotNil(surface.textInputs[input], line: line)
        let handle = surface.element(at: CGPoint(x: 150, y: 125)) { $0.acceptsPointer }
        XCTAssertEqual(surface.layout.core.layoutFrame(of: handle).width, 12, line: line)
        let corner = 12.0 * 13 / 18
        assertEqual(
            CGRect(surface.presentedFrame(of: handle)),
            CGRect(x: Self.scaled.maxX - corner, y: Self.scaled.maxY - corner, width: corner, height: corner),
            accuracy: 0.05,
            line: line
        )
    }

    func testScaleHandlePresentsProportionallyWithTheContentCornerFixed() throws {
        for animations in [true, false] {
            let clock = Clock()
            let fixture = try Fixture(Self.followBody, animations: animations) { clock.now }
            let surface = fixture.surface
            dragScale(fixture)
            assertEqual(try XCTUnwrap(surface.manipulation?.preview), Self.scaled)
            if animations {
                clock.now += 0.02
                let moving = try presented(fixture)
                XCTAssertEqual(moving.origin, Self.home.origin)
                XCTAssertGreaterThan(moving.width, Self.scaled.width)
                clock.now += 2
            } else {
                let state = try wrapper(fixture)
                XCTAssertEqual(state.layer.transform.m11, 13 / 18, accuracy: 1e-6)
                XCTAssertEqual(state.layer.transform.m41, 0)
            }
            let presentation = try XCTUnwrap(surface.presentation)
            XCTAssertEqual(try XCTUnwrap(presentation.targets[fixture.target()]).scale, 13 / 18, accuracy: 1e-3)
            assertEqual(try presented(fixture), Self.scaled, accuracy: 0.05)
            try assertScaledHits(fixture)
            surface.cancelInput()
        }
    }

    func testScaleCommitRebasesAndDropsDescendantAnimationsForThatBatch() throws {
        let clock = Clock()
        let fixture = try follow(clock: clock)
        let renderer = try attachRenderer(fixture)
        let surface = fixture.surface
        let handle = try XCTUnwrap(surface.layout.core.elements { $0.gestureTrack != 0 }.first {
            surface.layout.core.layoutFrame(of: $0).width == 12
        })
        dragScale(fixture)
        clock.now += 0.05
        let invocation = try fixture.releaseMove(at: CGPoint(x: 145, y: 125))
        let held = try presented(fixture)
        try fixture.invokeRelease()
        fixture.render(acknowledgement: invocation)
        let layout = CGRect(try surface.layout.core.absoluteFrame(of: fixture.target()))
        assertEqual(layout, Self.scaled)
        XCTAssertEqual(try record(fixture)?.motion?.target, layout)
        try assertEqual(presented(fixture), held)
        XCTAssertEqual(
            try surface.presentation?.targets[fixture.target()]?.scale ?? 0,
            Float(held.width / layout.width),
            accuracy: 1e-5
        )
        let scene = surface.scene
        let animations = ShellLayerScene.engineQueue.sync { scene.layers[handle.slot]?.animationKeys() ?? [] }
        XCTAssertFalse(animations.contains { $0.hasPrefix("position") || $0.hasPrefix("bounds") })
        XCTAssertNotNil(surface.animation(for: handle))
        XCTAssertFalse(surface.followSuppressesAnimation(of: try fixture.target()))
        withExtendedLifetime(renderer) {}
    }

    func testRegrabMidSettleContinuesFromThePresentedState() throws {
        for scale in [false, true] {
            let clock = Clock()
            let fixture = try follow(clock: clock)
            let surface = fixture.surface
            try commitMove(fixture, to: CGPoint(x: 185, y: 75), clock: clock)
            clock.now += 0.05
            let shown = try presented(fixture)
            let layout = CGRect(try surface.layout.core.absoluteFrame(of: fixture.target()))
            XCTAssertNotEqual(shown.origin, layout.origin)
            let grab = scale ? CGPoint(x: shown.maxX - 5, y: shown.maxY - 5) : CGPoint(
                x: shown.minX + 5,
                y: shown.minY + 5
            )
            surface.press(at: grab, timestamp: 1)
            surface.drag(to: CGPoint(x: grab.x + 8, y: grab.y + 8), screen: .zero, timestamp: 1.01)
            let current = try XCTUnwrap(surface.manipulation)
            XCTAssertEqual(current.recipe.mode, scale ? .scale : .move)
            assertEqual(current.start, scale ? CGRect(origin: shown.origin, size: layout.size) : layout, accuracy: 1e-3)
            try assertEqual(presented(fixture), shown)
            surface.cancelInput()
        }
    }

    func testRegionsCoverTheTrajectoryUntilTheSettleCompletes() async throws {
        let clock = Clock()
        let fixture = try follow(Self.snapBody, clock: clock)
        let renderer = try attachRenderer(fixture)
        let surface = fixture.surface
        let exact = surface.islandRegions()
        let release = CGPoint(x: 430, y: 110)
        XCTAssertFalse(exact.contains { $0.contains(release) })
        fixture.beginMove(to: CGPoint(x: 385, y: 75))
        clock.now += 2
        let invocation = try fixture.releaseMove(at: CGPoint(x: 385, y: 75))
        try fixture.invokeRelease()
        fixture.render(acknowledgement: invocation)
        XCTAssertEqual(try record(fixture)?.motion?.target, Self.home)
        let moving = surface.islandRegions()
        let trajectory = try XCTUnwrap(record(fixture)?.motion?.trajectoryBounds)
        XCTAssertEqual(moving, [trajectory.intersection(CGRect(origin: .zero, size: surface.view.bounds.size))])
        XCTAssertTrue(moving.contains { $0.contains(release) })
        XCTAssertTrue(moving.contains { $0.contains(CGPoint(x: Self.home.midX, y: Self.home.midY)) })
        let (completion, animation) = try completion(fixture)
        completion.animationDidStop(animation, finished: true)
        await drain()
        XCTAssertNil(try record(fixture)?.motion)
        XCTAssertEqual(surface.islandRegions(), exact)
        withExtendedLifetime(renderer) {}
    }

    func testFrameChangeMidSettleRetargetsAndIgnoresTheSupersededSegment() async throws {
        let clock = Clock()
        let fixture = try follow(Self.shiftBody, clock: clock)
        let renderer = try attachRenderer(fixture)
        let surface = fixture.surface
        let target = try fixture.target()
        try commitMove(fixture, to: CGPoint(x: 185, y: 75), clock: clock)
        clock.now += 0.05
        let superseded = try XCTUnwrap(record(fixture)?.token)
        let shown = try presented(fixture)
        setVars(fixture, "shift", -10)
        fixture.render()
        let layout = CGRect(surface.layout.core.absoluteFrame(of: target))
        XCTAssertEqual(layout.minX, 170)
        XCTAssertEqual(try record(fixture)?.motion?.target, layout)
        XCTAssertNotEqual(try record(fixture)?.token, superseded)
        try assertEqual(presented(fixture), shown)
        XCTAssertEqual(try wrapper(fixture).layer.transform.m41, 0)
        surface.manipulationSettled(target.slot, token: superseded)
        XCTAssertNotNil(try record(fixture)?.motion)
        let (completion, animation) = try completion(fixture)
        completion.animationDidStop(animation, finished: true)
        await drain()
        XCTAssertNil(try record(fixture)?.motion)
        withExtendedLifetime(renderer) {}
    }

    func testOneToOneResizeCommitOnAFollowTargetPresentsImmediately() throws {
        let clock = Clock()
        let fixture = try follow(
            Self.followBody.replacingOccurrences(of: "mode='scale'", with: "mode='resize'"),
            clock: clock
        )
        let surface = fixture.surface
        surface.press(at: CGPoint(x: 175, y: 145), timestamp: 0)
        surface.drag(to: CGPoint(x: 165, y: 137), screen: .zero, timestamp: 0.01)
        XCTAssertEqual(surface.manipulation?.preview, CGRect(x: 80, y: 70, width: 90, height: 72))
        XCTAssertNil(try record(fixture)?.motion)
        let invocation = try fixture.releaseMove(at: CGPoint(x: 165, y: 137))
        try fixture.invokeRelease()
        fixture.render(acknowledgement: invocation)
        XCTAssertNil(surface.manipulation)
        XCTAssertEqual(
            CGRect(try surface.layout.core.absoluteFrame(of: fixture.target())),
            CGRect(x: 80, y: 70, width: 90, height: 72)
        )
        XCTAssertNil(try record(fixture)?.motion)
        XCTAssertNil(surface.presentation)
        XCTAssertFalse(try wrapper(fixture).moving)
    }

    func testHidingMidSettleFinishesItSynchronouslyOnce() async throws {
        let clock = Clock()
        let fixture = try follow(clock: clock)
        let renderer = try attachRenderer(fixture)
        let surface = fixture.surface
        try commitMove(fixture, to: CGPoint(x: 185, y: 75), clock: clock)
        let (completion, animation) = try completion(fixture)
        var moves = 0
        surface.onMove = { moves += 1 }
        surface.setVisible(false)
        XCTAssertEqual(moves, 1)
        XCTAssertNil(try record(fixture)?.motion)
        XCTAssertNil(surface.presentation)
        let state = try wrapper(fixture)
        XCTAssertFalse(state.moving)
        XCTAssertFalse(state.raised)
        XCTAssertEqual(state.layer.zPosition, 0)
        completion.animationDidStop(animation, finished: true)
        await drain()
        XCTAssertEqual(moves, 1)
        withExtendedLifetime(renderer) {}
    }

    func testCompletionMovesOnceLowersAndRecentresEvenAfterAClickToFront() async throws {
        for clicks in [false, true] {
            let clock = Clock()
            let fixture = try follow(clock: clock)
            let renderer = try attachRenderer(fixture)
            let surface = fixture.surface
            let target = try fixture.target()
            try commitMove(fixture, to: CGPoint(x: 185, y: 75), clock: clock)
            let (completion, animation) = try completion(fixture)
            if clicks {
                let shown = try presented(fixture)
                surface.selectManipulation(at: CGPoint(x: shown.minX + 10, y: shown.minY + 40))
                XCTAssertEqual(surface.selectedManipulation, target)
                XCTAssertTrue(try wrapper(fixture).raised)
            }
            var moves = 0
            surface.onMove = { moves += 1 }
            completion.animationDidStop(animation, finished: true)
            completion.animationDidStop(animation, finished: true)
            await drain()
            XCTAssertEqual(moves, 1)
            XCTAssertNil(try record(fixture)?.motion)
            ShellLayerScene.engineQueue.sync {}
            XCTAssertEqual(try wrapper(fixture).layer.zPosition, clicks ? 1 : 0)
            if clicks { fixture.render() }
            let state = try wrapper(fixture)
            XCTAssertEqual(state.layer.zPosition, 0)
            XCTAssertFalse(state.moving)
            let content = try ShellLayerScene.engineQueue.sync { try XCTUnwrap(surface.scene.layers[target.slot]) }
            let centre = ShellLayerScene.engineQueue.sync {
                CGPoint(
                    x: content.position.x + content.bounds.width / 2,
                    y: content.position.y + content.bounds.height / 2
                )
            }
            XCTAssertEqual(state.layer.position, centre)
            withExtendedLifetime(renderer) {}
        }
    }

    func testGestureTrackOnTheTargetFinishesAnInFlightSettle() throws {
        let clock = Clock()
        let body = Self.followBody.replacingOccurrences(
            of: "manipulationFollow={response=0.363,bounce=0.42},fill='surface',",
            with: "manipulationFollow={response=0.363,bounce=0.42},fill='surface',"
                + "gesture={axis='y',commit={distance=20},track={dy={0,20}}},onGesture=function() end,"
        )
        let fixture = try follow(body, clock: clock)
        let surface = fixture.surface
        try commitMove(fixture, to: CGPoint(x: 185, y: 75), clock: clock)
        XCTAssertTrue(try wrapper(fixture).moving)
        let shown = try presented(fixture)
        let point = CGPoint(x: shown.minX + 50, y: shown.minY + 65)
        surface.press(at: point, timestamp: 1)
        surface.drag(to: CGPoint(x: point.x, y: point.y + 10), screen: .zero, timestamp: 1.01)
        let tracking = try XCTUnwrap(surface.gestureTracking)
        XCTAssertEqual(tracking.handle, try fixture.target())
        XCTAssertNil(try record(fixture)?.motion)
        let state = try wrapper(fixture)
        XCTAssertFalse(state.moving)
        XCTAssertEqual(state.token, tracking.token)
        surface.cancelInput()
    }
}
