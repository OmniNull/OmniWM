// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
extension ShellRevealTests {
    func testShapeStopsInterpolateOffsetsAndThicknessWithoutLosingTheOldSampler() throws {
        let recipe = try XCTUnwrap(ShellMorphRecipe(
            "morph:0:0:0:0:0:0:0,0.5,1,1,1,0;1,1,1,1,1,1|offsets:2,4,1;10,20,3"
        ))
        let stop = recipe.stop(at: 0.5)
        XCTAssertEqual(stop.dx, 6)
        XCTAssertEqual(stop.dy, 12)
        XCTAssertEqual(stop.thickness, 2)
        let base = ShellGlassShape(
            slot: 4,
            kind: 2,
            rect: CGRect(x: 20, y: 30, width: 100, height: 80),
            radius: 12,
            thickness: 5
        )
        let shape = recipe.shape(base, progress: 0.5, velocity: 0)
        XCTAssertEqual(shape.rect, CGRect(x: 26, y: 42, width: 75, height: 60))
        XCTAssertEqual(shape.thickness, 7.5)
        XCTAssertEqual(shape.slot, base.slot)
        XCTAssertEqual(shape.kind, base.kind)
        let old = recipe.shape(base.rect, radius: base.radius, progress: 0.5, velocity: 0)
        XCTAssertEqual(old.rect, shape.rect)
        XCTAssertEqual(old.radius, shape.radius)
    }

    func testAnalyticCrossingsIncludeEveryRisingAndFallingRecrossing() throws {
        let spring = ShellMorphRecipe.Spring(response: 0.307, bounce: 0.68).parameters
        let plan = ShellReveal(begin: 7, progress: 0, target: 1, spring: spring)
        for rising in [false, true] {
            let times = plan.crossings(at: 1, rising: rising)
            XCTAssertGreaterThanOrEqual(times.count, 2)
            for time in times {
                let state = plan.state(at: time)
                XCTAssertEqual(state.progress, 1, accuracy: 1e-10)
                XCTAssertEqual(state.velocity > 0, rising)
                XCTAssertLessThan(time, plan.end)
            }
            let dense = stride(from: 0.0001, through: plan.duration, by: 0.0001).filter { elapsed in
                let before = plan.state(at: plan.begin + elapsed - 0.0001).progress - 1
                let after = plan.state(at: plan.begin + elapsed).progress - 1
                return rising ? before < 0 && after >= 0 : before > 0 && after <= 0
            }
            XCTAssertEqual(times.count, dense.count)
            for (time, elapsed) in zip(times, dense) {
                XCTAssertEqual(time - plan.begin, elapsed, accuracy: 0.0001)
            }
        }
        XCTAssertTrue(plan.crossings(at: 4, rising: true).isEmpty)
        let drip = try ShellReveal(begin: 0, progress: 0, target: 1, spring: Self.drip())
        XCTAssertEqual(try XCTUnwrap(drip.crossings(at: 0.97, rising: true).first), 0.230, accuracy: 0.005)
    }

    func testImpulsesUseExactCrossingAndCommitTimesAndPreserveBothStateChannels() throws {
        let morph = try XCTUnwrap(ShellMorphRecipe(
            "morph:0.5:0:0:0:0:0:0,1,1,1,1,1;1,1,1,1,1,1"
                + "|impulses:0,0.97,1,0.307,0.68,220,0,1,0;1,0.031,1,0.307,0.68,-260,1,1,1"
        ))
        let plan = try ShellReveal(begin: 10.2, progress: 0, target: 1, spring: Self.drip())
        let impulses = ShellShapeImpulse.scheduled(morph.impulses, on: plan, commit: 10)
        let after = try XCTUnwrap(impulses.first { $0.pivot == .centre })
        let at = try XCTUnwrap(impulses.first { $0.pivot == .anchor })
        XCTAssertEqual(after.begin, 10.031, accuracy: 1e-12)
        XCTAssertEqual(at.begin, try XCTUnwrap(plan.crossings(at: 0.97, rising: true).first), accuracy: 1e-12)
        XCTAssertEqual(after.state(at: after.begin - 0.001).displacement, 0)
        let time = at.begin + 0.04
        let carrying = try XCTUnwrap(at.carrying(at: time))
        XCTAssertEqual(carrying.state(at: time).displacement, at.state(at: time).displacement, accuracy: 1e-12)
        XCTAssertEqual(carrying.state(at: time).velocity, at.state(at: time).velocity, accuracy: 1e-12)
        XCTAssertEqual(
            carrying.state(at: time + 0.02).displacement,
            at.state(at: time + 0.02).displacement,
            accuracy: 1e-10
        )
        XCTAssertNil(at.carrying(at: at.begin - 0.001))
        XCTAssertNil(at.carrying(at: at.end))
    }

    func testImpulsePivotsKeepTheAnchorOrCentrePinned() throws {
        let base = ShellGlassShape(
            slot: 1,
            kind: 0,
            rect: CGRect(x: 40, y: 30, width: 200, height: 100),
            radius: 10,
            thickness: 0
        )
        let spring = ShellMorphRecipe.Spring(response: 0.307, bounce: 0.68)
        let sag = ShellShapeImpulse(
            .init(
                kind: .after,
                time: 0,
                rising: true,
                spring: spring,
                velocity: 220,
                width: 0,
                height: 1,
                pivot: .anchor
            ),
            begin: 0
        )
        let wobble = ShellShapeImpulse(
            .init(
                kind: .after,
                time: 0,
                rising: true,
                spring: spring,
                velocity: -260,
                width: 1,
                height: -0.5,
                pivot: .centre
            ),
            begin: 0
        )
        let frequency = 2 * Double.pi / spring.response
        let decay = (1 - spring.bounce) * frequency
        let oscillation = sqrt(frequency * frequency - decay * decay)
        let peak = atan(oscillation / decay) / oscillation
        let expectedSag = 220 / oscillation * exp(-decay * peak) * sin(oscillation * peak)
        XCTAssertEqual(
            sag.apply(to: base, anchor: CGPoint(x: 0.5, y: 0), at: peak).rect.height - base.rect.height,
            expectedSag,
            accuracy: 0.2
        )
        let expectedWobble = -260 / oscillation * exp(-decay * peak) * sin(oscillation * peak)
        XCTAssertEqual(
            wobble.apply(to: base, anchor: .zero, at: peak).rect.width - base.rect.width,
            expectedWobble,
            accuracy: 0.2
        )
        for time in [0.01, 0.035, peak, 0.16, 0.25] {
            let anchored = sag.apply(to: base, anchor: CGPoint(x: 0.5, y: 0), at: time)
            XCTAssertEqual(anchored.rect.minY, base.rect.minY, accuracy: 1e-12)
            XCTAssertEqual(anchored.rect.height - base.rect.height, sag.state(at: time).displacement, accuracy: 1e-12)
            let centred = wobble.apply(to: base, anchor: .zero, at: time)
            XCTAssertEqual(centred.rect.midX, base.rect.midX, accuracy: 1e-12)
            XCTAssertEqual(centred.rect.midY, base.rect.midY, accuracy: 1e-12)
            XCTAssertEqual(centred.rect.width - base.rect.width, wobble.state(at: time).displacement, accuracy: 1e-12)
        }
    }

    func testEdgeSpringsMatchTheClosedFormsAndThinTheCrossAxis() {
        let recipe = ShellMorphRecipe.Edges(
            lead: .init(response: 0.142, bounce: 0), trail: .init(response: 0.378, bounce: 0), thin: 0.18, unit: 29
        )
        let start = CGRect(x: 20, y: 30, width: 29, height: 15)
        let target = start.offsetBy(dx: 80, dy: 0)
        let edges = ShellShapeEdges(from: start, to: target, recipe: recipe, begin: 5)
        for elapsed in [0, 0.02, 0.06, 0.13, 0.3] {
            let first = target.minX + ShellSpringDynamics.position(
                at: elapsed, displacement: -80, initialVelocity: 0, spring: recipe.trail.parameters
            )
            let last = target.maxX + ShellSpringDynamics.position(
                at: elapsed, displacement: -80, initialVelocity: 0, spring: recipe.lead.parameters
            )
            let shape = edges.rect(at: 5 + elapsed)
            XCTAssertEqual(shape.minX, first, accuracy: 1e-9)
            XCTAssertEqual(shape.maxX, max(first, last), accuracy: 1e-9)
            XCTAssertEqual(shape.midY, start.midY, accuracy: 1e-9)
            XCTAssertEqual(shape.height, 15 * (1 - 0.18 * min(1, abs(shape.width - 29) / 29)), accuracy: 1e-9)
        }
    }

    func testEdgeRetargetCarriesGeometryAndVelocityEvenAtFullThinning() {
        for thin in [0.18, 1] {
            let recipe = ShellMorphRecipe.Edges(
                lead: .init(response: 0.142, bounce: 0), trail: .init(response: 0.378, bounce: 0), thin: thin, unit: 29
            )
            let start = CGRect(x: 20, y: 30, width: 29, height: 15)
            let edges = ShellShapeEdges(from: start, to: start.offsetBy(dx: 80, dy: 0), recipe: recipe, begin: 0)
            let time = 0.06
            let next = edges.retargeted(to: start.offsetBy(dx: -20, dy: 15), at: time)
            let before = edges.state(at: time), after = next.state(at: time)
            XCTAssertEqual(after.rect.minX, before.rect.minX, accuracy: 1e-9)
            XCTAssertEqual(after.rect.minY, before.rect.minY, accuracy: 1e-9)
            XCTAssertEqual(after.rect.width, before.rect.width, accuracy: 1e-9)
            XCTAssertEqual(after.rect.height, before.rect.height, accuracy: 1e-9)
            for lane in 0 ..< 4 { XCTAssertEqual(after.velocity[lane], before.velocity[lane], accuracy: 1e-7) }
            XCTAssertEqual(next.rect(at: next.end), next.target)
        }
    }
}
