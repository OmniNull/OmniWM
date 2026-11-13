// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class ShellPathAnimationTests: XCTestCase {
    private let side = 100
    private let targetInset = 25
    private let duration = 2.5
    private let inProgress = [0.25, 0.5, 0.75]
    private let afterCompletion = 2.0
    private let probeClearance = 3
    private let gaugeSide = 72
    private let bandWidth = 12
    private let mostlyCovered = 0.75

    private var center: Int {
        side / 2
    }

    func testRepaintingAPathBorderDoesNotDrawARectangularOutline() throws {
        let paint = "fill = 0, borderWidth = 4, border = changed and '#0000FFFF' or '#FF0000FF'"
        let frames = try animatedDiamondFrames(paint: paint)
        for (fraction, pixels) in frames.animated {
            XCTAssertEqual(alpha(pixels, x: 0, y: center), 0, "Outside the stroke at \(fraction)")
            XCTAssertEqual(alpha(pixels, x: center, y: center), 0, "Inside the hollow path at \(fraction)")
            XCTAssertEqual(alpha(pixels, x: vertexInset(at: fraction), y: center), .max, "On the stroke at \(fraction)")
        }
    }

    func testRepaintingAnAnimatedPathPreservesItsContourBetweenEndpoints() throws {
        let frames = try animatedDiamondFrames(paint: "fill = changed and '#0000FFFF' or '#FF0000FF'")
        XCTAssertEqual(alpha(frames.initial, x: 0, y: 0), 0)
        XCTAssertEqual(alpha(frames.initial, x: center, y: center), .max)
        for (fraction, pixels) in frames.animated {
            XCTAssertEqual(alpha(pixels, x: 0, y: 0), 0, "Outside the contour at \(fraction)")
            XCTAssertEqual(alpha(pixels, x: center, y: center), .max, "Inside the contour at \(fraction)")
            let top = vertexInset(at: fraction)
            XCTAssertEqual(alpha(pixels, x: center, y: top - probeClearance), 0, "Above the contour at \(fraction)")
            XCTAssertEqual(alpha(pixels, x: center, y: top + probeClearance), .max, "Below the contour at \(fraction)")
        }
    }

    func testStatsGaugeMorphsAlongTheRing() throws {
        let widget = try statsGauge(side: gaugeSide)
        let frames = try animatedFrames(widget, side: gaugeSide, duration: try statsGaugeDuration())
        let initial = gaugeRadii(frames.initial)
        let ring = try settledRing(frames)
        let animated = try frames.animated.map { fraction, pixels in
            let radii = gaugeRadii(pixels)
            XCTAssertGreaterThanOrEqual(
                try XCTUnwrap(radii.min()),
                ring.lowerBound,
                "Stroke bent inward at \(fraction)"
            )
            XCTAssertLessThanOrEqual(try XCTUnwrap(radii.max()), ring.upperBound, "Stroke bent outward at \(fraction)")
            return (fraction, radii.count)
        }
        let midpoint = try XCTUnwrap(animated.first { $0.0 == 0.5 }?.1)
        XCTAssertGreaterThan(midpoint, initial.count)
        XCTAssertLessThan(midpoint, try XCTUnwrap(animated.last?.1))
    }

    func testCelestialGaugeBandMorphsAlongItsRing() throws {
        for (start, target) in [(20, 40), (40, 20), (10, 90), (90, 10)] {
            let transition = "\(start)% to \(target)%"
            let widget = try celestialGauge(from: start, to: target)
            let frames = try animatedFrames(widget, side: gaugeSide, duration: duration)
            let outer = Double(gaugeSide) / 2
            let inner = outer - Double(bandWidth)
            var covered = gaugeRadii(frames.initial).count
            for (fraction, pixels) in frames.animated {
                let radii = gaugeRadii(pixels)
                let at = "\(transition) at \(fraction)"
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(radii.min()), inner, "Band bent inward, \(at)")
                XCTAssertLessThanOrEqual(try XCTUnwrap(radii.max()), outer, "Band bent outward, \(at)")
                if target > start {
                    XCTAssertGreaterThan(radii.count, covered, "Band stopped growing, \(at)")
                } else {
                    XCTAssertLessThan(radii.count, covered, "Band stopped shrinking, \(at)")
                }
                covered = radii.count
            }
        }
    }

    func testRetargetingTheCelestialGaugeBandStartsAtTheDisplayedSweep() throws {
        let widget = try celestialGauge(from: 20, to: 80, then: 40)
        let start = CACurrentMediaTime()
        widget.surface.clock = { start }
        widget.render(ShellBarData())
        let renderer = try pausedRenderer(widget, side: gaugeSide, at: start)
        widget.resources.motion.userAnimationsEnabled = true
        widget.set("seconds") { $0.number(1) }
        widget.render(ShellBarData())
        let retarget = start + duration / 2
        let before = try ShellLayerScene.engineQueue.sync { try renderer.render(paused: retarget) }
        widget.surface.clock = { retarget }
        widget.set("seconds") { $0.number(2) }
        widget.render(ShellBarData())
        let after = try ShellLayerScene.engineQueue.sync { try renderer.render(paused: retarget) }
        let settled = try ShellLayerScene.engineQueue.sync {
            try renderer.render(paused: retarget + duration * afterCompletion)
        }
        XCTAssertEqual(gaugeRadii(after), gaugeRadii(before))
        XCTAssertLessThan(gaugeRadii(settled).count, gaugeRadii(before).count)
    }

    func testCircularArcMorphPreservesRadiusAcrossRotationChanges() throws {
        let arcDuration = 0.2
        for (startRotation, targetRotation) in [(0, 90), (0, 180), (-1, 1), (179, 1)] {
            let widget = try ShellRenderedWidget(name: "arc-rotation", source: """
            function render(ctx)
                local changed = ctx.data.seconds == 1
                local d = changed and 'M12 2.5 A9.5 9.5 \(targetRotation) 0 1 17.58 19.69'
                    or 'M12 2.5 A9.5 9.5 \(startRotation) 0 1 21.04 9.06'
                return ui.path{ key = 'arc', w = \(gaugeSide), h = \(gaugeSide), viewBox = {0, 0, 24, 24},
                    d = d, border = '#FF0000FF', borderWidth = 2.6,
                    animate = { duration = \(arcDuration), curve = 'linear' } }
            end
            """, scale: 1)
            let frames = try animatedFrames(widget, side: gaugeSide, duration: arcDuration)
            let midpoint = try XCTUnwrap(frames.animated.first { $0.fraction == 0.5 }?.pixels)
            let final = try XCTUnwrap(frames.animated.last?.pixels)
            let ring = try settledRing(frames)
            let radii = gaugeRadii(midpoint)
            let transition = "\(startRotation)° to \(targetRotation)°"
            XCTAssertGreaterThan(radii.count, gaugeRadii(frames.initial).count, transition)
            XCTAssertLessThan(radii.count, gaugeRadii(final).count, transition)
            XCTAssertGreaterThanOrEqual(
                try XCTUnwrap(radii.min()), ring.lowerBound, "Stroke bent inward during \(transition)"
            )
            XCTAssertLessThanOrEqual(
                try XCTUnwrap(radii.max()), ring.upperBound, "Stroke bent outward during \(transition)"
            )
        }
    }

    func testRetargetingTheStatsGaugeStartsAtTheDisplayedSweep() throws {
        let widget = try statsGauge(side: gaugeSide)
        let duration = try statsGaugeDuration()
        let start = CACurrentMediaTime()
        widget.surface.clock = { start }
        widget.render(ShellBarData())
        let renderer = try pausedRenderer(widget, side: gaugeSide, at: start)
        widget.resources.motion.userAnimationsEnabled = true
        widget.set("seconds") { $0.number(1) }
        widget.render(ShellBarData())
        let retarget = start + duration / 2
        let before = try ShellLayerScene.engineQueue.sync { try renderer.render(paused: retarget) }
        widget.surface.clock = { retarget }
        widget.set("seconds") { $0.number(2) }
        widget.render(ShellBarData())
        let after = try ShellLayerScene.engineQueue.sync { try renderer.render(paused: retarget) }
        let settled = try ShellLayerScene.engineQueue.sync {
            try renderer.render(paused: retarget + duration * afterCompletion)
        }
        let beforeRadii = gaugeRadii(before)
        XCTAssertEqual(gaugeRadii(after), beforeRadii)
        XCTAssertLessThan(gaugeRadii(settled).count, beforeRadii.count)
    }

    func testIncompatiblePathsShowTheDestinationImmediately() throws {
        let widget = try ShellRenderedWidget(name: "incompatible-paths", source: """
        function render(ctx)
            local changed = ctx.data.seconds == 1
            return ui.path{ w = \(side), h = \(side), fill = '#FF0000FF',
                d = changed and 'M50 25 L75 50 L50 75 L25 50 Z' or 'M50 0 L100 100 L0 100 Z',
                animate = { duration = \(duration), curve = 'linear' } }
        end
        """)
        let frames = try animatedFrames(widget, side: side, duration: duration)
        let target = try XCTUnwrap(frames.animated.last?.pixels)
        XCTAssertNotEqual(frames.initial, target)
        for (_, pixels) in frames.animated.dropLast() {
            XCTAssertEqual(pixels, target)
        }
    }

    private func statsGauge(side: Int) throws -> ShellRenderedWidget {
        let bundled = try ShellRenderedWidget.bundledSource("stats")
        return try ShellRenderedWidget(name: "stats-gauge", source: """
        local stats = require("../lib/stats")
        function render(ctx)
            local value = if ctx.data.seconds == 1 then 40 elseif ctx.data.seconds == 2 then 25 else 20
            return stats.gauge(value, \(side), '#FF0000FF', ui.box{})
        end
        """, modules: bundled.modules, chunk: bundled.chunk, scale: 1)
    }

    private func statsGaugeDuration() throws -> Double {
        var seconds: Double?
        if case let .ease(duration) = ShellMotion.ease { seconds = duration }
        return try XCTUnwrap(seconds, "The stats gauge animates with the ease preset")
    }

    private func celestialGauge(from start: Int, to target: Int, then next: Int? = nil) throws -> ShellRenderedWidget {
        let geometry = try String(
            contentsOf: ShellStyleFixture.source("celestial").appendingPathComponent("lib/geometry.luau"),
            encoding: .utf8
        )
        return try ShellRenderedWidget(
            name: "celestial-gauge",
            source: """
            local geometry = require("../lib/geometry")
            function render(ctx)
                local percent = if ctx.data.seconds == 1 then \(target)
                    elseif ctx.data.seconds == 2 then \(next ?? target) else \(start)
                return ui.path{ key = 'gauge', w = \(gaugeSide), h = \(gaugeSide), fill = '#FF0000FF',
                    d = geometry.gauge(\(gaugeSide), \(bandWidth), percent / 100).value,
                    animate = { duration = \(duration), curve = 'linear' } }
            end
            """,
            modules: [.init(path: "celestial/lib/geometry.luau", source: geometry)],
            chunk: "@celestial/widgets/gauge.luau",
            scale: 1
        )
    }

    private func settledRing(
        _ frames: (initial: [UInt8], animated: [(fraction: Double, pixels: [UInt8])])
    ) throws -> ClosedRange<Double> {
        let settled = gaugeRadii(frames.initial) + gaugeRadii(try XCTUnwrap(frames.animated.last?.pixels))
        return try XCTUnwrap(settled.min()) ... XCTUnwrap(settled.max())
    }

    private func gaugeRadii(_ pixels: [UInt8]) -> [Double] {
        let center = Double(gaugeSide) / 2
        let covered = UInt8(mostlyCovered * Double(UInt8.max))
        let clear = UInt8.max - covered
        return (0 ..< gaugeSide * gaugeSide).compactMap { index in
            let offset = index * 4
            guard pixels[offset + 2] > covered, pixels[offset + 1] < clear, pixels[offset] < clear else { return nil }
            return hypot(Double(index % gaugeSide) + 0.5 - center, Double(index / gaugeSide) + 0.5 - center)
        }
    }

    private func animatedDiamondFrames(
        paint: String
    ) throws -> (initial: [UInt8], animated: [(fraction: Double, pixels: [UInt8])]) {
        let far = side - targetInset
        let widget = try ShellRenderedWidget(name: "path-animation", source: """
        function render(ctx)
            local changed = ctx.data.seconds == 1
            return ui.path{ key = 'marker', w = \(side), h = \(side), \(paint),
                d = changed and 'M\(center) \(targetInset) L\(far) \(center) L\(center) \(far) L\(targetInset) \(center) Z'
                    or 'M\(center) 0 L\(side) \(center) L\(center) \(side) L0 \(center) Z',
                animate = { duration = \(duration), curve = 'linear' } }
        end
        """)
        return try animatedFrames(widget, side: side, duration: duration)
    }

    private func animatedFrames(
        _ widget: ShellRenderedWidget, side: Int, duration: CFTimeInterval
    ) throws -> (initial: [UInt8], animated: [(fraction: Double, pixels: [UInt8])]) {
        let start = CACurrentMediaTime()
        widget.surface.clock = { start }
        widget.render(ShellBarData())
        let renderer = try pausedRenderer(widget, side: side, at: start)
        let initial = try ShellLayerScene.engineQueue.sync { try renderer.render(paused: start) }
        widget.resources.motion.userAnimationsEnabled = true
        widget.set("seconds") { $0.number(1) }
        widget.render(ShellBarData())
        let animated = try (inProgress + [afterCompletion]).map { fraction in
            try (
                fraction,
                ShellLayerScene.engineQueue.sync { try renderer.render(paused: start + duration * fraction) }
            )
        }
        return (initial, animated)
    }

    private func pausedRenderer(
        _ widget: ShellRenderedWidget, side: Int, at time: CFTimeInterval
    ) throws -> ShellOffscreenRenderer {
        try ShellLayerScene.engineQueue.sync {
            let root = widget.surface.scene.container
            root.frame = CGRect(x: 0, y: 0, width: side, height: side)
            root.speed = 0
            root.timeOffset = time
            return try ShellOffscreenRenderer(root: root, width: side, height: side)
        }
    }

    private func vertexInset(at fraction: Double) -> Int {
        Int(Double(targetInset) * min(fraction, 1))
    }

    private func alpha(_ pixels: [UInt8], x: Int, y: Int) -> UInt8 {
        pixels[(y * side + x) * 4 + 3]
    }
}
