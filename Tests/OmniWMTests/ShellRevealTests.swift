// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellRevealTests: XCTestCase {
    typealias Fixture = ShellManipulationSurfaceTests.Fixture
    typealias Clock = ShellManipulationSurfaceTests.Clock

    nonisolated static func lf(_ at: Double) -> Double {
        min(1, 1.6 * at) + 0.6 * max(0, at - 1)
    }

    nonisolated static func bell(_ at: Double) -> Double {
        4 * min(1, at) * (1 - min(1, at))
    }

    nonisolated static let glassMorph = "morph:1:0.5:0.07:0.5:1:-0.5:" + [
        0, 0.0625, 0.125, 0.25, 0.375, 0.5, 0.625, 0.6875, 0.75, 0.875, 1, 1.25
    ].map { at in
        "\(at),\(lf(at)),1,\(1 - 0.07 * bell(at)),1,\(min(1, max(0, 1.6 * at - 0.1)))"
    }.joined(separator: ";")

    nonisolated static let contentMorph = "morph:1:0.5:0:0:0:0:0,0.05,0,1,1,1;0.02,0.05,0,1,1,1;"
        + "0.0201,0.05,1,1,1,1;0.03125,0.05,1,1,1,1;0.625,1,1,1,1,1;1,1,1,1,1,1;1.25,1.15,1,1,1,1"

    nonisolated static func drip() throws -> ShellSpringDynamics.Parameters {
        try XCTUnwrap(ShellSpringDynamics.Parameters(
            ShellAnimation(motion: .spring(response: 0.482, bounce: 0.31), speed: 1)
        ))
    }

    private func first(_ plan: ShellReveal, where condition: (Double, Double) -> Bool) -> Double? {
        stride(from: 0.0, through: 1.5, by: 0.0005).first {
            let state = plan.state(at: plan.begin + $0)
            return condition(state.progress, state.velocity)
        }
    }

    func testDripSamplerMatchesTheVitreusOpenAndCloseTimeline() throws {
        let spring = try Self.drip()
        let recipe = try XCTUnwrap(ShellMorphRecipe(Self.glassMorph))
        let opening = ShellReveal(begin: 0, progress: 0, target: 1, spring: spring)
        XCTAssertEqual(
            try XCTUnwrap(first(opening) { progress, _ in recipe.stop(at: progress).scale >= 1 }),
            0.130,
            accuracy: 0.005
        )
        XCTAssertEqual(
            try XCTUnwrap(first(opening) { progress, _ in recipe.stop(at: progress).round >= 1 }),
            0.144,
            accuracy: 0.005
        )
        let state = opening.state(at: 0.084)
        XCTAssertEqual(state.velocity, 6.05, accuracy: 0.1)
        XCTAssertEqual(recipe.stretching(at: state.velocity), 0.42, accuracy: 0.01)
        let layout = CGRect(x: 40, y: 30, width: 438.43, height: 571.32)
        let stop = recipe.stop(at: state.progress)
        let base = recipe.scaled(layout, by: stop.scale)
        XCTAssertEqual(stop.scale, 0.577, accuracy: 0.02)
        XCTAssertEqual(base.maxX, layout.maxX, accuracy: 1e-9)
        XCTAssertEqual(base.midY, layout.midY, accuracy: 1e-9)
        let shape = recipe.shape(layout, radius: 32, progress: state.progress, velocity: state.velocity)
        XCTAssertEqual(shape.rect.width / base.width, 1.359, accuracy: 0.005)
        XCTAssertEqual(shape.rect.height / base.height, 0.788, accuracy: 0.005)
        XCTAssertEqual(shape.rect.midX, base.midX, accuracy: 1e-9)
        XCTAssertEqual(shape.rect.midY, base.midY, accuracy: 1e-9)
        XCTAssertGreaterThan(shape.rect.maxX, layout.maxX)
        let closing = ShellReveal(begin: 0, progress: 1, target: 0, spring: spring)
        XCTAssertEqual(try XCTUnwrap(first(closing) { progress, _ in progress <= 0.02 }), 0.234, accuracy: 0.005)
        XCTAssertEqual(recipe.stretching(at: closing.state(at: 0.1).velocity), 0)
    }

    func testSamplesRunAtOneHundredTwentyHertzToTheAnalyticBoundAndEndOnTheTarget() throws {
        let plan = try ShellReveal(begin: 5, progress: 0, target: 1, spring: Self.drip())
        let samples = plan.samples
        XCTAssertEqual(samples.count, Int((plan.duration * ShellReveal.rate).rounded(.up)) + 1)
        for (index, sample) in samples.dropLast().enumerated() {
            XCTAssertEqual(sample.time, Double(index) / 120, accuracy: 1e-12)
        }
        XCTAssertEqual(samples.first?.progress, 0)
        XCTAssertEqual(samples.last?.time, plan.duration)
        XCTAssertEqual(samples.last?.progress, 1)
        XCTAssertEqual(samples.last?.velocity, 0)
        let tail = plan.state(at: plan.end - 1e-6)
        XCTAssertLessThan(abs(tail.progress - 1), 0.002)
        XCTAssertLessThan(abs(tail.velocity), 0.02)
        XCTAssertEqual(plan.state(at: plan.end).progress, 1)
        let reversed = plan.retargeted(at: 5.1, to: 0)
        XCTAssertEqual(reversed.progress, plan.state(at: 5.1).progress)
        XCTAssertEqual(reversed.velocity, plan.state(at: 5.1).velocity)
    }

    func testStopsArePiecewiseLinearAndClampedAtBothEnds() throws {
        let recipe = try XCTUnwrap(ShellMorphRecipe(Self.contentMorph))
        XCTAssertEqual(recipe.stop(at: -0.3).scale, 0.05)
        XCTAssertEqual(recipe.stop(at: -0.3).opacity, 0)
        XCTAssertEqual(recipe.stop(at: 0.02).opacity, 0)
        XCTAssertEqual(recipe.stop(at: 0.0201).opacity, 1)
        XCTAssertEqual(recipe.stop(at: (0.03125 + 0.625) / 2).scale, 0.525, accuracy: 1e-12)
        XCTAssertEqual(recipe.stop(at: 1.125).scale, 1.075, accuracy: 1e-12)
        XCTAssertEqual(recipe.stop(at: 3).scale, 1.15)
    }

    func testCoreQueriesEnterAScaledGroupAndSkipAHiddenOne() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.stack{w=300,h=200,
                ui.stack{key='group',align='topLeading',dx=100,dy=50,w=100,h=100,
                    ui.box{key='child',align='topLeading',dx=50,dy=0,w=50,h=50,onClick=function() end}}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let text = ShellTextStore()
        text.ingest(wire: script.output)
        let layout = ShellWidgetLayout()
        XCTAssertTrue(layout.apply(script.output, text: text))
        let child = try XCTUnwrap(layout.core.elements { $0.action != 0 }.first)
        let group = layout.core.parent(of: child)
        let scaled = SurfacePresentation(groups: [
            group: .init(frame: Rect(x: 150, y: 75, width: 50, height: 50), scale: 0.5, visible: true)
        ])
        XCTAssertEqual(layout.core.hitTest(x: 180, y: 80, presentation: scaled) { $0.action != 0 }, child)
        XCTAssertEqual(layout.core.hitTest(x: 160, y: 80, presentation: scaled) { $0.action != 0 }, .none)
        XCTAssertEqual(layout.core.hitTest(x: 170, y: 120, presentation: scaled) { $0.action != 0 }, .none)
        XCTAssertTrue(layout.core.covers(x: 180, y: 80, presentation: scaled) { $0 == child })
        XCTAssertEqual(layout.core.hitPath(x: 180, y: 80, presentation: scaled) { $0.action != 0 }, [child])
        let hidden = SurfacePresentation(groups: [
            group: .init(frame: Rect(x: 100, y: 50, width: 100, height: 100), scale: 1, visible: false)
        ])
        XCTAssertEqual(layout.core.hitTest(x: 175, y: 75, presentation: hidden) { $0.action != 0 }, .none)
        XCTAssertFalse(layout.core.covers(x: 175, y: 75, presentation: hidden) { $0 == child })
        XCTAssertEqual(layout.core.hitPath(x: 175, y: 75, presentation: hidden) { _ in true }, [layout.core.rootHandle])
        XCTAssertEqual(layout.core.hitTest(x: 175, y: 75) { $0.action != 0 }, child)
    }
}
