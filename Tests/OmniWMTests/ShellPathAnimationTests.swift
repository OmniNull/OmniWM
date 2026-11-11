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
        let start = CACurrentMediaTime()
        widget.surface.clock = { start }
        widget.render(ShellBarData())
        let renderer = try ShellLayerScene.engineQueue.sync {
            let root = widget.surface.scene.container
            root.frame = CGRect(x: 0, y: 0, width: side, height: side)
            root.speed = 0
            root.timeOffset = start
            return try ShellOffscreenRenderer(root: root, width: side, height: side)
        }
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

    private func vertexInset(at fraction: Double) -> Int {
        Int(Double(targetInset) * min(fraction, 1))
    }

    private func alpha(_ pixels: [UInt8], x: Int, y: Int) -> UInt8 {
        pixels[(y * side + x) * 4 + 3]
    }
}
