// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class ShellBoundTrackMathTests: XCTestCase {
    private let spring = ShellSpringDynamics.Parameters(mass: 1, stiffness: 300, damping: 20)
    private let layout = CGRect(x: 90, y: 70, width: 120, height: 96)
    private let canvas = CGRect(x: -20, y: -30, width: 600, height: 400)

    private func source(_ edge: ShellMorphRecipe.SourceEdge) -> ShellMorphRecipe.Source {
        ShellMorphRecipe.Source(target: 7, edge: edge, from: 14, span: 50, pads: nil)
    }

    private func gap(_ rect: CGRect, edge: ShellMorphRecipe.SourceEdge) -> Double {
        switch edge {
        case .top: rect.minY - canvas.minY
        case .left: rect.minX - canvas.minX
        case .right: canvas.maxX - rect.maxX
        case .bottom: canvas.maxY - rect.maxY
        }
    }

    private func rect(_ wrapper: ShellWrapperMotion, at time: Double) -> CGRect {
        CGRect(
            x: layout.minX + wrapper.x.value(at: time),
            y: layout.minY + wrapper.y.value(at: time),
            width: layout.width * wrapper.scale.value(at: time),
            height: layout.height * wrapper.scale.value(at: time)
        )
    }

    private func motion() throws -> ShellManipulationMotion {
        try XCTUnwrap(ShellManipulationMotion(
            from: CGRect(x: 100, y: 60, width: 130, height: 104),
            velocity: .init(x: 80, y: -50, width: -20),
            to: CGRect(x: 130, y: 45, width: 90, height: 72), begin: 2.7, spring: spring
        ))
    }

    func testProjectedProgressEqualsThePresentedGapOnAllFourEdgesWithoutClamping() throws {
        let motion = try motion()
        let wrapper = motion.wrapper(for: layout)
        for edge in [ShellMorphRecipe.SourceEdge.top, .left, .right, .bottom] {
            let recipe = source(edge)
            let plan = wrapper.progress(in: layout, canvas: canvas, source: recipe)
            XCTAssertEqual(plan.begin, motion.begin)
            XCTAssertEqual(plan.commit, motion.begin)
            XCTAssertEqual(plan.duration, motion.duration)
            XCTAssertEqual(plan.spring.mass, spring.mass)
            XCTAssertEqual(plan.spring.stiffness, spring.stiffness)
            XCTAssertEqual(plan.spring.damping, spring.damping)
            for elapsed in [0, 0.01, 0.11, 0.2, 0.5, motion.duration, motion.duration + 1] {
                let time = motion.begin + elapsed
                let expected = (gap(rect(wrapper, at: time), edge: edge) - recipe.from) / recipe.span
                XCTAssertEqual(plan.state(at: time).progress, expected, accuracy: 1e-11, "\(edge) at \(elapsed)")
            }
            XCTAssertGreaterThan(plan.progress, 1)
        }
    }

    func testProjectedVelocityEqualsTheGapDerivativeAndSurvivesAReversalRetarget() throws {
        let original = try motion()
        let time = original.begin + 0.145
        let reversed = try XCTUnwrap(original.retargeted(
            at: time, to: CGRect(x: 60, y: 110, width: 150, height: 120)
        ))
        for edge in [ShellMorphRecipe.SourceEdge.top, .left, .right, .bottom] {
            let recipe = source(edge)
            let prior = original.wrapper(for: layout).progress(in: layout, canvas: canvas, source: recipe)
            let next = reversed.wrapper(for: layout).progress(in: layout, canvas: canvas, source: recipe)
            let velocity = original.velocity(at: time)
            let derivative: Double = switch edge {
            case .left: velocity.x
            case .top: velocity.y
            case .right: -velocity.x - velocity.width
            case .bottom: -velocity.y - velocity.width * layout.height / layout.width
            }
            XCTAssertEqual(prior.state(at: time).velocity, derivative / recipe.span, accuracy: 1e-11)
            XCTAssertEqual(next.progress, prior.state(at: time).progress, accuracy: 1e-11)
            XCTAssertEqual(next.velocity, prior.state(at: time).velocity, accuracy: 1e-11)
            XCTAssertEqual(next.begin, time)
            XCTAssertEqual(next.duration, reversed.duration)
        }
    }

    func testAnOvershootingSettleCrossesTheDetachThresholdAndReturnsThroughIt() throws {
        let motion = try XCTUnwrap(ShellManipulationMotion(
            from: CGRect(x: 0, y: 0, width: 100, height: 80),
            to: CGRect(x: 44.5, y: 0, width: 100, height: 80), begin: 8, spring: spring
        ))
        let origin = CGRect(x: 0, y: 0, width: 100, height: 80)
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let plan = motion.wrapper(for: origin).progress(in: origin, canvas: bounds, source: source(.left))
        let rising = plan.crossings(at: 0.7, rising: true)
        let falling = plan.crossings(at: 0.7, rising: false)
        XCTAssertEqual(rising.count, 1)
        XCTAssertEqual(falling.count, 1)
        let first = try XCTUnwrap(rising.first), second = try XCTUnwrap(falling.first)
        XCTAssertLessThan(first, second)
        for (crossing, direction) in [(first, 1.0), (second, -1.0)] {
            XCTAssertEqual(plan.state(at: crossing).progress, 0.7, accuracy: 1e-11)
            XCTAssertGreaterThan(plan.state(at: crossing).velocity * direction, 0)
            XCTAssertLessThan(plan.state(at: crossing - 1e-6).progress * direction, 0.7 * direction)
            XCTAssertGreaterThan(plan.state(at: crossing + 1e-6).progress * direction, 0.7 * direction)
        }
    }

    func testProjectedCrossingsKeepEveryRecrossingWithinTheNativeWrapperLifetime() throws {
        let motion = try XCTUnwrap(ShellManipulationMotion(
            from: CGRect(x: 0, y: 0, width: 100, height: 80),
            to: CGRect(x: 49, y: 0, width: 100, height: 80), begin: 8,
            spring: .init(mass: 1, stiffness: 300, damping: 6)
        ))
        let origin = CGRect(x: 0, y: 0, width: 100, height: 80)
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        let plan = motion.wrapper(for: origin).progress(in: origin, canvas: bounds, source: source(.left))
        let expected = 0.7
        let crossings = (plan.crossings(at: expected, rising: true) + plan.crossings(at: expected, rising: false))
            .sorted()
        XCTAssertGreaterThanOrEqual(crossings.count, 4)
        XCTAssertEqual(Set(crossings).count, crossings.count)
        for crossing in crossings {
            XCTAssertGreaterThanOrEqual(crossing, plan.begin)
            XCTAssertLessThanOrEqual(crossing, plan.end)
            XCTAssertEqual(plan.state(at: crossing).progress, expected, accuracy: 1e-11)
        }
        XCTAssertEqual(plan.state(at: plan.end).progress, plan.target)
        XCTAssertEqual(plan.state(at: plan.end).velocity, 0)
    }

    func testOnlyTheSourceEdgeAttachesWhileTheOtherSidesStayOnThePresentedTarget() {
        let input = ShellBoundInput(
            layout: CGRect(x: 411, y: 70, width: 200, height: 160),
            canvas: CGRect(x: 0, y: 0, width: 700, height: 400),
            presentation: .still(translation: CGPoint(x: -20, y: -40), scale: 1, clip: nil),
            active: true, time: 0
        )
        let source = ShellMorphRecipe.Source(
            target: 7, edge: .right, from: 114, span: 50,
            pads: .init(left: 0, right: 13, top: 0, bottom: 0)
        )
        let bound = ShellBoundTrack(input: input, source: source, previous: nil, revision: 1)
        let raw = ShellGlassShape(
            slot: 1, kind: 0, rect: CGRect(x: 400, y: 70, width: 226, height: 160), radius: 10, thickness: 0
        )
        let placed = bound.place(raw, progress: bound.state(at: 0).progress, at: 0)
        XCTAssertEqual(bound.state(at: 0).progress, 0)
        XCTAssertEqual(placed.rect.minX, 391)
        XCTAssertEqual(placed.rect.minY, 30)
        XCTAssertEqual(placed.rect.maxX, 626)
        XCTAssertEqual(placed.rect.maxY, 190)
        XCTAssertTrue(placed.rect.contains(input.rect(at: 0)))
    }

    func testExtraAttachingSidesUseTheirOwnGapsAndOriginsWithoutScalingTheReach() {
        let input = ShellBoundInput(
            layout: layout, canvas: canvas,
            presentation: .still(translation: CGPoint(x: -100, y: -90), scale: 0.8, clip: nil),
            active: true, time: 0
        )
        let source = ShellMorphRecipe.Source(
            target: 7, edge: .right, from: 490, span: 50,
            pads: .init(left: -13, right: 13, top: -13, bottom: 13),
            adhere: .init(top: 8, left: 0, bottom: 310)
        )
        let bound = ShellBoundTrack(input: input, source: source, previous: nil, revision: 1)
        let raw = ShellGlassShape(
            slot: 1, kind: 0, rect: CGRect(x: -46, y: -56, width: 652, height: 452), radius: 10, thickness: 0
        )
        let placed = bound.place(raw, progress: bound.state(at: 0).progress, at: 0)
        XCTAssertEqual(bound.state(at: 0).progress, 0.08, accuracy: 1e-12)
        XCTAssertEqual(placed.rect.minX, -40.88, accuracy: 1e-12)
        XCTAssertEqual(placed.rect.maxX, 565.232, accuracy: 1e-12)
        XCTAssertEqual(placed.rect.minY, -54.976, accuracy: 1e-12)
        XCTAssertEqual(placed.rect.maxY, 374.9568, accuracy: 1e-12)
        XCTAssertEqual(placed.radius, 8)
    }

    func testClampCrossingsIncludeTheSourceAndEveryExtraAttachingSide() throws {
        let layout = CGRect(x: 0, y: 0, width: 100, height: 80)
        let canvas = CGRect(x: 0, y: 0, width: 600, height: 400)
        let motion = try XCTUnwrap(ShellManipulationMotion(
            from: layout, to: layout.offsetBy(dx: 100, dy: 100), begin: 8, spring: spring
        ))
        let wrapper = motion.wrapper(for: layout)
        let source = ShellMorphRecipe.Source(
            target: 7, edge: .left, from: 14, span: 50,
            pads: .init(left: 0, right: 0, top: 0, bottom: 0), adhere: .init(top: 30)
        )
        let top = ShellMorphRecipe.Source(target: 7, edge: .top, from: 30, span: 50, pads: nil)
        let begin = motion.begin + 0.03
        let bound = ShellBoundTrack(
            input: .init(layout: layout, canvas: canvas, presentation: .motion(wrapper), active: false, time: begin),
            source: source, previous: nil, revision: 1
        )
        let plans = [source, top].map { wrapper.progress(in: layout, canvas: canvas, source: $0) }
        let expected = Array(Set(plans.flatMap { plan in
            [0.0, 1.0].flatMap { value in
                plan.crossings(at: value, rising: true) + plan.crossings(at: value, rising: false)
            }
        }.filter { $0 >= begin && $0 <= motion.begin + motion.duration })).sorted()
        XCTAssertGreaterThanOrEqual(expected.count, 4)
        XCTAssertEqual(bound.clampCrossings, expected)
    }
}
