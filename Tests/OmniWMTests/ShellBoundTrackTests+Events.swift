// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
extension ShellBoundTrackTests {
    func testCrossingImpulsesAndPulseShapesFireOnceAndNoopSubmitsPreserveThem() throws {
        let begin = CACurrentMediaTime()
        let fixture = try Fixture(Self.pulseBody, animations: true, clock: { begin })
        let source = try helper.shape(fixture, "bound").slot
        let up = try helper.shape(fixture, "up").slot
        let down = try helper.shape(fixture, "down").slot
        let input = try input(at: begin)
        send(input, to: source, on: fixture)
        let before = try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            let entry = try XCTUnwrap(scene.shapeTracks.entries[source])
            let bound = try XCTUnwrap(entry.bound)
            let rising = bound.crossings(at: 0.7, rising: true)
            let falling = bound.crossings(at: 0.7, rising: false)
            XCTAssertEqual(rising.count, 1)
            XCTAssertEqual(falling.count, 1)
            XCTAssertEqual(entry.impulses.map(\.begin).sorted(), (rising + falling).sorted())
            XCTAssertEqual(Set(entry.impulses.map(\.velocity)), [-280, 80])
            for (slot, starts) in [(up, rising), (down, falling)] {
                let pulse = try XCTUnwrap(scene.shapeTracks.entries[slot])
                XCTAssertEqual(pulse.triggerPlans.map(\.begin), starts)
                let start = try XCTUnwrap(starts.first)
                XCTAssertEqual(pulse.shape(at: start - 0.001).rect.width, 0, accuracy: 1e-9)
                XCTAssertGreaterThan(pulse.shape(at: start + 0.03).rect.width, 1)
                XCTAssertTrue(pulse.animations
                    .contains { ($0.animation as? CAKeyframeAnimation)?.values?.isEmpty == false })
            }
            return [
                entry.generation,
                try XCTUnwrap(scene.shapeTracks.entries[up]?.generation),
                try XCTUnwrap(scene.shapeTracks.entries[down]?.generation)
            ]
        }
        let duplicate = ShellBoundInput(
            layout: input.layout,
            canvas: input.canvas,
            presentation: input.presentation,
            active: input.active,
            time: begin + 0.001
        )
        send(duplicate, to: source, on: fixture)
        fixture.surface.scene.submit([.raise(slot: try fixture.target().slot, false)], animated: false)
        ShellLayerScene.engineQueue.sync {}
        let after = ShellLayerScene.engineQueue.sync {
            [source, up, down].compactMap { fixture.surface.scene.shapeTracks.entries[$0]?.generation }
        }
        XCTAssertEqual(after, before)
    }

    func testOnePulseCanReplayAtEveryAnalyticRecrossingAndRetargetDropsFutureEvents() throws {
        let begin = CACurrentMediaTime()
        let fixture = try Fixture(Self.pulseBody, animations: true, clock: { begin })
        let source = try helper.shape(fixture, "bound").slot
        let up = try helper.shape(fixture, "up").slot
        let spring = ShellSpringDynamics.Parameters(mass: 1, stiffness: 100, damping: 2)
        let first = try input(at: begin, spring: spring)
        send(first, to: source, on: fixture)
        let starts = try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            let bound = try XCTUnwrap(scene.shapeTracks.entries[source]?.bound)
            let starts = bound.crossings(at: 0.7, rising: true)
            XCTAssertGreaterThan(starts.count, 1)
            XCTAssertEqual(scene.shapeTracks.entries[up]?.triggerPlans.map(\.begin), starts)
            return starts
        }
        let firstStart = try XCTUnwrap(starts.first)
        let secondStart = try XCTUnwrap(starts.dropFirst().first)
        let time = (firstStart + secondStart) / 2
        let motion = try XCTUnwrap(ShellManipulationMotion(
            from: first.layout, to: first.layout.offsetBy(dx: -32.5, dy: 0), begin: begin, spring: spring
        ))
        let next = try XCTUnwrap(motion.retargeted(at: time, to: first.layout))
        send(
            ShellBoundInput(
                layout: first.layout,
                canvas: first.canvas,
                presentation: .motion(next.wrapper(for: first.layout)),
                active: false,
                time: time
            ),
            to: source,
            on: fixture
        )
        try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            let bound = try XCTUnwrap(scene.shapeTracks.entries[source]?.bound)
            let planned = try XCTUnwrap(scene.shapeTracks.entries[up]).triggerPlans.map(\.begin)
            XCTAssertEqual(planned.filter { $0 <= time }, [firstStart])
            XCTAssertEqual(planned.filter { $0 > time }, bound.crossings(at: 0.7, rising: true))
        }
    }

    func testReducedMotionStepsTheSourceWithoutSchedulingPulseAnimations() throws {
        let begin = CACurrentMediaTime()
        let fixture = try Fixture(Self.pulseBody, animations: false, clock: { begin })
        let source = try helper.shape(fixture, "bound").slot
        let up = try helper.shape(fixture, "up").slot
        send(ShellBoundInput(
            layout: CGRect(x: 386, y: 70, width: 200, height: 160),
            canvas: CGRect(x: 0, y: 0, width: 700, height: 400),
            presentation: .still(translation: CGPoint(x: -40, y: 0), scale: 1, clip: nil),
            active: true,
            time: begin,
            animates: false
        ), to: source, on: fixture)
        try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            let entry = try XCTUnwrap(scene.shapeTracks.entries[source])
            XCTAssertEqual(entry.bound?.state(at: begin).progress, 0.8)
            XCTAssertTrue(entry.impulses.isEmpty)
            XCTAssertTrue(entry.animations.isEmpty)
            let pulse = try XCTUnwrap(scene.shapeTracks.entries[up])
            XCTAssertEqual(pulse.triggerPlans.count, 1)
            XCTAssertEqual(pulse.triggerPlans.first?.duration, 0)
            XCTAssertTrue(pulse.animations.isEmpty)
        }
    }
}
