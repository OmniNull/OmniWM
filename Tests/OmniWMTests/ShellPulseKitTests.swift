// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class ShellPulseKitTests: XCTestCase {
    private let springs: [(Double, Double)] = [(0.307, 0.68), (0.482, 0.31), (0.926, 0.41), (0.36, 0)]

    private func widget(_ body: String) throws -> ShellRenderedWidget {
        let root = try ShellStyleFixture.source("vitreus").appendingPathComponent("lib/vitreus")
        let modules = try ["kit", "palette", "pencil"].map {
            ShellWidgetSource.Module(
                path: "vitreus/lib/vitreus/\($0).luau",
                source: try String(contentsOf: root.appendingPathComponent("\($0).luau"), encoding: .utf8)
            )
        }
        let widget = try ShellRenderedWidget(
            name: "pulse-kit", source: """
            local kit = require('../lib/vitreus/kit')
            function render(ctx)
                \(body)
            end
            """, modules: modules, chunk: "@vitreus/widgets/probe.luau"
        )
        widget.render(ShellBarData(monitor: "test"))
        return widget
    }

    private func values(_ body: String) throws -> [Double] {
        let widget = try widget("""
        local values = {}
        \(body)
        for index, value in ipairs(values) do values[index] = string.format('%.17g', value) end
        return ui.text{text=table.concat(values, ',')}
        """)
        let text = try XCTUnwrap(widget.strings().first)
        let fields = text.split(separator: ",", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { Double($0) }
        XCTAssertEqual(numbers.count, fields.count, text)
        return numbers
    }

    private func native(_ response: Double, _ bounce: Double) throws -> ShellSpringDynamics.Parameters {
        try XCTUnwrap(ShellSpringDynamics.Parameters(
            ShellAnimation(motion: .spring(response: response, bounce: bounce), speed: 1)
        ))
    }

    func testLabelAndZoneForwardPulseAndTextShadow() throws {
        let widget = try widget("""
        local c = kit.canvas(200, 100, 1, 1)
        return ui.stack{w=200,h=100,
            kit.label(c, {key='clock',text='12:34',size=16,x=100,y=25,
                shadow='#112233',shadowRadius=3,shadowOffset={x=0,y=1},
                pulse={key='clock',duration=0.5,rotate={0,12,0}}}),
            kit.zone(c, {key='button',x=100,y=75,w=80,h=30,
                pulse={key='button',duration=0.3,scale={0,0.1,0}}})}
        """)
        let label = try XCTUnwrap(widget.tree().first { $0.kind == .label })
        XCTAssertEqual(label.paint.shadowRadius, 3)
        XCTAssertEqual(label.paint.shadowOffsetX, 0)
        XCTAssertEqual(label.paint.shadowOffsetY, 1)
        XCTAssertTrue(label.paint.shadow.isVisible)
        let pulse = try XCTUnwrap(ShellPulseRecipe(widget.text.string(label.paint.pulse)))
        XCTAssertEqual(pulse.duration, 0.5)
        XCTAssertEqual(pulse.rotate, [0, 12, 0])
        let zone = try XCTUnwrap(widget.tree().first { $0.kind == .group && $0.paint.pulse != 0 })
        let zonePulse = try XCTUnwrap(ShellPulseRecipe(widget.text.string(zone.paint.pulse)))
        XCTAssertEqual(zonePulse.duration, 0.3)
        XCTAssertEqual(zonePulse.scale, [0, 0.1, 0])
    }

    func testSpringStatesAndImpulseResponsesMatchTheRecipeDynamics() throws {
        let times = [0.0, 0.01, 0.083, 0.333, 1, 2]
        for (response, bounce) in springs {
            let spring = ShellMorphRecipe.Spring(response: response, bounce: bounce).parameters
            for (from, velocity, target) in [(0.0, 0.0, 1.0), (0.4, -3, 0), (1.2, 4, 0.7)] {
                let result = try values("""
                local spring = {response=\(response), bounce=\(bounce)}
                for _, elapsed in ipairs({\(times.map(String.init(describing:)).joined(separator: ","))}) do
                    local position, velocity = kit.springState(spring, \(from), \(velocity), elapsed, \(target))
                    table.insert(values, position)
                    table.insert(values, velocity)
                    table.insert(values, kit.impulse(spring, 7, elapsed))
                end
                """)
                XCTAssertEqual(result.count, times.count * 3)
                guard result.count == times.count * 3 else { continue }
                for (index, time) in times.enumerated() {
                    XCTAssertEqual(result[index * 3], target + ShellSpringDynamics.position(
                        at: time, displacement: from - target, initialVelocity: velocity, spring: spring
                    ))
                    XCTAssertEqual(result[index * 3 + 1], ShellSpringDynamics.velocity(
                        at: time, displacement: from - target, initialVelocity: velocity, spring: spring
                    ))
                    XCTAssertEqual(result[index * 3 + 2], ShellSpringDynamics.position(
                        at: time, displacement: 0, initialVelocity: 7, spring: spring
                    ))
                }
            }
        }
    }

    private static let dampingRoundedOperations = 4

    func testNativeSpringsMatchTheRecipeDynamicsForEveryKitSpring() throws {
        let fields = try values("""
        for _, spring in kit.springs do
            table.insert(values, spring.response)
            table.insert(values, spring.bounce)
        end
        """)
        XCTAssertFalse(fields.isEmpty)
        for index in stride(from: 0, to: fields.count, by: 2) {
            let played = try native(fields[index], fields[index + 1])
            let recipe = ShellMorphRecipe.Spring(response: fields[index], bounce: fields[index + 1]).parameters
            XCTAssertEqual(played.mass, recipe.mass)
            XCTAssertEqual(played.stiffness, recipe.stiffness)
            XCTAssertEqual(
                played.damping,
                recipe.damping,
                accuracy: .rounding(operations: Self.dampingRoundedOperations, at: recipe.damping)
            )
        }
    }

    func testCrossingsIncludeOvershootRecrossingsAndVelocityBearingRetargets() throws {
        for (response, bounce, from, velocity, target, threshold, rising, after) in [
            (0.482, 0.31, 0.0, 0.0, 1.0, 0.97, true, 0.0),
            (0.307, 0.68, 0.0, 0.0, 1.0, 1.0, false, 0.0),
            (0.307, 0.68, 0.0, 0.0, 1.0, 1.0, true, 0.3),
            (0.926, 0.41, 1.0, 0.0, 0.0, 0.5, false, 0.0),
            (0.482, 0.31, 0.7, -4.0, 1.0, 0.84, true, 0.0),
            (0.36, 0.0, 0.0, 0.0, 1.0, 0.3, true, 0.0)
        ] {
            let spring = ShellMorphRecipe.Spring(response: response, bounce: bounce).parameters
            let crossing = try XCTUnwrap(referenceCrossing(
                spring, from: from, velocity: velocity, target: target,
                threshold: threshold, rising: rising, after: after
            ))
            let result = try values("""
            local spring = {response=\(response), bounce=\(bounce)}
            table.insert(values, kit.springCrossing(spring, \(from), \(velocity), \(target),
                \(threshold), \(rising), \(after)) or -1)
            """)
            XCTAssertEqual(
                try XCTUnwrap(result.first),
                crossing,
                accuracy: Self.crossingStep / Double(1 << Self.crossingBisections)
            )
        }
        let absent = try values("""
        table.insert(values, kit.springCrossing(kit.springs.drip, 0, 0, 1, 4, true) or -1)
        table.insert(values, kit.springCrossing(kit.springs.fd0, 0, 0, 1, 1, true) or -1)
        """)
        XCTAssertEqual(absent, [-1, -1])
    }

    private static let crossingStep = 0.0005
    private static let crossingBisections = 32

    private func referenceCrossing(
        _ spring: ShellSpringDynamics.Parameters, from: Double, velocity: Double, target: Double,
        threshold: Double, rising: Bool, after: Double
    ) -> Double? {
        func value(_ time: Double) -> Double {
            target + ShellSpringDynamics.position(
                at: time, displacement: from - target, initialVelocity: velocity, spring: spring
            ) - threshold
        }
        var low = after
        for _ in 0 ..< 10_000 {
            var high = low + Self.crossingStep
            if (rising && value(low) < 0 && value(high) >= 0)
                || (!rising && value(low) > 0 && value(high) <= 0)
            {
                for _ in 0 ..< Self.crossingBisections {
                    let middle = (low + high) / 2
                    if (value(middle) > 0) == rising { high = middle } else { low = middle }
                }
                return (low + high) / 2
            }
            low = high
        }
        return nil
    }

    func testSettleMatchesTheSharedDynamicsDuration() throws {
        for (response, bounce) in springs {
            let spring = ShellMorphRecipe.Spring(response: response, bounce: bounce).parameters
            let result = try values("""
            table.insert(values, kit.springSettle({response=\(response), bounce=\(bounce)}, 0, 3, 1))
            """)
            let expected = ShellSpringDynamics.settleTime(
                displacement: SIMD4(-1, 0, 0, 0), velocity: SIMD4(3, 0, 0, 0), spring: spring,
                residual: 0.001, speed: 0.001
            )
            XCTAssertEqual(try XCTUnwrap(result.first), expected)
        }
    }

    func testBellSamplesUseDegreesAndPreserveTheAnalyticPeak() throws {
        let samples = try values("values = kit.sampleBell()")
        XCTAssertEqual(samples.count, 256)
        guard samples.count == 256 else { return }
        XCTAssertEqual(samples.first, 0)
        XCTAssertEqual(samples.last, 0)
        let amplitude = 24.0, duration = 2.4, rate = 6.64 / duration, swing = 2000 * Double.pi / 180
        func bell(_ time: Double) -> Double {
            let phase = time * rate
            let progress = 1 - exp(-phase) * (1 + phase)
            return amplitude * (1 - progress) * sin(progress * swing)
        }
        let dense = (0 ... 4096).map { bell(duration * Double($0) / 4096) }
        let peak = try XCTUnwrap(dense.map { abs($0) }.max())
        let sharpestBend = amplitude * rate * rate * (1 + swing + (2 * swing + swing * swing) * exp(-2.0))
        let denseSpacing = duration / Double(dense.count - 1)
        let firstSineCrest = amplitude * (1 - .pi / 2 / swing)
        XCTAssertGreaterThanOrEqual(peak, firstSineCrest - denseSpacing * denseSpacing / 8 * sharpestBend)
        let spacing = duration / Double(samples.count - 1)
        let chordGap = spacing * spacing / 8 * sharpestBend
        XCTAssertEqual(try XCTUnwrap(samples.map { abs($0) }.max()), peak, accuracy: chordGap)
        for (index, expected) in dense.enumerated() {
            let phase = Double(index) / 4096 * 255
            let low = min(Int(phase), 254)
            let fraction = phase - Double(low)
            let actual = samples[low] + (samples[low + 1] - samples[low]) * fraction
            XCTAssertEqual(actual, expected, accuracy: chordGap + abs(bell(duration)))
        }
    }

    func testImpulseSamplesEndAtNeutralWithoutChangingEarlierSamples() throws {
        let duration = 1.5
        let samples = try values("values = kit.sampleImpulse(kit.springs.splash, -12, \(duration))")
        XCTAssertEqual(samples.count, 256)
        guard samples.count == 256 else { return }
        XCTAssertEqual(samples.first, 0)
        XCTAssertEqual(samples.last, 0)
        let spring = ShellMorphRecipe.Spring(response: 0.307, bounce: 0.68).parameters
        for index in 0 ..< 255 {
            let time = duration * Double(index) / 255
            XCTAssertEqual(samples[index], ShellSpringDynamics.position(
                at: time, displacement: 0, initialVelocity: -12, spring: spring
            ))
        }
    }
}
