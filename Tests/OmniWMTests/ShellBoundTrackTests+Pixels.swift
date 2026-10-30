// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class ShellBoundTrackPixelTests: XCTestCase {
    private typealias Fixture = ShellBoundSurfaceFixture
    private let pixels = ShellGlassSceneTests()
    private let helper = ShellManipulationSurfaceTests()

    private func check(
        _ fixture: Fixture.Fixture,
        on stage: ShellGlassSceneTests.FollowStage,
        at time: CFTimeInterval,
        accuracy: Double = 1
    ) throws {
        let expected = try Fixture.expected(fixture)
        let actual = try pixels.drawn(stage, at: time, around: expected)
        print("BOUND-PIXELS", time, "actual", actual, "expected", expected)
        Fixture.assertRect(actual, expected, accuracy: accuracy)
    }

    func testBoundPadsKeepTheAttachedReachUnscaledAtScalePointEightAndDetPointThree() throws {
        let begin = CACurrentMediaTime()
        let fixture = try Fixture.Fixture(Fixture.body, animations: false, clock: { begin })
        let stage = try Fixture.stage(fixture, at: begin)
        let shape = try Fixture.element(fixture, "bound")
        try pixels.requireNative(stage, Fixture.element(fixture, "panes").slot)
        try Fixture.scale(fixture, to: 0.8)
        let expected = try Fixture.expected(fixture)
        XCTAssertEqual(expected.maxX, 626 * 0.7 + (571 + 13 * 0.8) * 0.3, accuracy: 1e-9)
        XCTAssertEqual(expected.maxX, 612.62, accuracy: 1e-9)
        XCTAssertEqual(fixture.surface.layout.core.content(of: shape).glassFollow, 0)
        XCTAssertNil(ShellLayerScene.engineQueue.sync { stage.scene.shapeTracks.follows[shape.slot] })
        try check(fixture, on: stage, at: begin)
        fixture.surface.cancelInput()
    }

    func testBoundGeometryRefreshesAfterABodyOnlyMoveAndSameKeyTargetReplacement() throws {
        let begin = CACurrentMediaTime()
        let fixture = try Fixture.Fixture(Fixture.body, animations: false, clock: { begin })
        let stage = try Fixture.stage(fixture, at: begin)
        let shape = try Fixture.element(fixture, "bound")
        let oldTarget = try fixture.target()
        let local = fixture.surface.layout.core.layoutFrame(of: shape)
        try Fixture.scale(fixture, to: 0.8)
        try check(fixture, on: stage, at: begin)
        helper.setValues(fixture, numbers: ["bodyX": 10])
        fixture.render()
        XCTAssertEqual(try Fixture.element(fixture, "bound"), shape)
        XCTAssertEqual(fixture.surface.layout.core.layoutFrame(of: shape), local)
        try check(fixture, on: stage, at: begin)
        helper.setValues(fixture, flags: ["replace": true])
        fixture.render()
        XCTAssertNotEqual(try fixture.target(), oldTarget)
        XCTAssertEqual(try Fixture.element(fixture, "bound"), shape)
        XCTAssertNil(fixture.surface.manipulation)
        try check(fixture, on: stage, at: begin)
    }

    func testBoundNativeSamplesMatchThePresentedSpringAcrossAVelocityRetarget() throws {
        let clock = Fixture.Clock()
        let fixture = try Fixture.Fixture(Fixture.body, animations: true, clock: { clock.now })
        let stage = try Fixture.stage(fixture, at: clock.now)
        let shape = try Fixture.element(fixture, "bound")
        let wire = fixture.script.output
        let begin = clock.now
        try Fixture.scale(fixture, to: 0.65)
        let generation = ShellLayerScene.engineQueue.sync { stage.scene.shapeTracks.entries[shape.slot]?.generation }
        for elapsed in [0.04, 0.08, 0.12] {
            clock.now = begin + elapsed
            try check(fixture, on: stage, at: clock.now, accuracy: 0.5)
        }
        XCTAssertEqual(ShellLayerScene.engineQueue.sync {
            stage.scene.shapeTracks.entries[shape.slot]?.generation
        }, generation)
        let before = try pixels.drawn(stage, at: clock.now, around: Fixture.expected(fixture))
        try Fixture.scale(fixture, to: 0.9, timestamp: 0.13)
        let after = try pixels.drawn(stage, at: clock.now, around: Fixture.expected(fixture))
        Fixture.assertRect(after, before, accuracy: 0.5)
        for elapsed in [0.15, 0.2, 0.3, 0.5] {
            clock.now = begin + elapsed
            try check(fixture, on: stage, at: clock.now, accuracy: 0.5)
        }
        XCTAssertEqual(fixture.script.output, wire)
        XCTAssertEqual(try Fixture.renderCount(fixture), "1")
        fixture.surface.cancelInput()
    }

    private func install(
        _ motion: ShellManipulationMotion, in fixture: Fixture.Fixture, active: Bool
    ) throws {
        let surface = fixture.surface
        let target = try fixture.target()
        let layout = CGRect(surface.layout.core.absoluteFrame(of: target))
        let token = try XCTUnwrap(surface.follows[target]?.token)
        surface.follows[target]?.motion = motion
        surface.scene.submit(surface.manipulationCommands(
            target, token: token, presentation: .motion(motion.wrapper(for: layout)), active: active
        ), animated: false)
        ShellLayerScene.engineQueue.sync {}
    }

    private func crossingMotion(
        _ fixture: Fixture.Fixture, at begin: CFTimeInterval
    ) throws -> ShellManipulationMotion {
        let layout = CGRect(fixture.surface.layout.core.absoluteFrame(of: try fixture.target()))
        return try XCTUnwrap(ShellManipulationMotion(
            from: layout, velocity: .init(x: -160, y: 40, width: -80),
            to: CGRect(x: 391, y: 90, width: 130, height: 104), begin: begin, spring: helper.desk
        ))
    }

    func testReleasedBoundSettleHasNativeKeysAtItsAnalyticClampCrossing() throws {
        let clock = Fixture.Clock()
        let fixture = try Fixture.Fixture(Fixture.body, animations: true, clock: { clock.now })
        let stage = try Fixture.stage(fixture, at: clock.now)
        let begin = clock.now
        try install(crossingMotion(fixture, at: begin), in: fixture, active: false)
        let slot = try Fixture.element(fixture, "bound").slot
        let crossing = try ShellLayerScene.engineQueue.sync {
            let entry = try XCTUnwrap(stage.scene.shapeTracks.entries[slot])
            let bound = try XCTUnwrap(entry.bound)
            let crossing = try XCTUnwrap(bound.plan.crossings(at: 1, rising: true).first)
            XCTAssertGreaterThan(crossing, begin)
            XCTAssertTrue(entry.samples.contains { abs(entry.begin + $0.time - crossing) < 1e-9 })
            return crossing
        }
        for time in [crossing - 1.0 / 600, crossing, crossing + 1.0 / 600] {
            clock.now = time
            try check(fixture, on: stage, at: time, accuracy: 0.5)
        }
    }

    func testActiveBoundRetargetMatchesNativePixelsWithinItsFirstInterval() throws {
        let clock = Fixture.Clock()
        let fixture = try Fixture.Fixture(Fixture.body, animations: true, clock: { clock.now })
        let stage = try Fixture.stage(fixture, at: clock.now)
        let first = try crossingMotion(fixture, at: clock.now)
        try install(first, in: fixture, active: true)
        clock.now = first.begin + 0.07
        try check(fixture, on: stage, at: clock.now, accuracy: 0.5)
        let next = try XCTUnwrap(first.retargeted(
            at: clock.now, to: CGRect(x: 371, y: 95, width: 180, height: 144)
        ))
        XCTAssertGreaterThan(abs(next.startVelocity.x) + abs(next.startVelocity.width), 1)
        try install(next, in: fixture, active: true)
        clock.now = next.begin + 1.0 / 180
        try check(fixture, on: stage, at: clock.now, accuracy: 0.5)
    }
}
