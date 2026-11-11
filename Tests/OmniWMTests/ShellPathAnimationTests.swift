// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class ShellPathAnimationTests: XCTestCase {
    func testRepaintingAPathBorderDoesNotDrawARectangularOutline() throws {
        let widget = try ShellRenderedWidget(name: "path-border-animation", source: """
        function render(ctx)
            local changed = ctx.data.seconds == 1
            return ui.path{ key = 'marker', w = 100, h = 100, fill = 0, borderWidth = 4,
                d = changed and 'M50 25 L75 50 L50 75 L25 50 Z' or 'M50 0 L100 50 L50 100 L0 50 Z',
                border = changed and '#0000FFFF' or '#FF0000FF',
                animate = { duration = 2.5, curve = 'linear' } }
        end
        """)
        let start = CACurrentMediaTime()
        widget.surface.clock = { start }
        widget.render(ShellBarData())
        let renderer = try ShellLayerScene.engineQueue.sync {
            let root = widget.surface.scene.container
            root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
            root.speed = 0
            root.timeOffset = start
            return try ShellOffscreenRenderer(root: root, width: 100, height: 100)
        }
        widget.resources.motion.userAnimationsEnabled = true
        widget.set("seconds") { $0.number(1) }
        widget.render(ShellBarData())
        for fraction in [0.25, 0.5, 0.75, 1.04] {
            let pixels = try ShellLayerScene.engineQueue.sync {
                try renderer.render(paused: start + 2.5 * fraction)
            }
            XCTAssertEqual(pixels[(50 * 100) * 4 + 3], 0, "Outside the stroke at \(fraction)")
            XCTAssertEqual(pixels[(50 * 100 + 50) * 4 + 3], 0, "Inside the hollow path at \(fraction)")
            let left = Int(25 * min(fraction, 1))
            XCTAssertGreaterThan(pixels[(50 * 100 + left) * 4 + 3], 128, "On the stroke at \(fraction)")
        }
    }

    func testRepaintingAnAnimatedPathPreservesItsContourBetweenEndpoints() throws {
        let widget = try ShellRenderedWidget(name: "path-animation", source: """
        function render(ctx)
            local changed = ctx.data.seconds == 1
            return ui.path{ key = 'marker', w = 100, h = 100,
                d = changed and 'M50 25 L75 50 L50 75 L25 50 Z' or 'M50 0 L100 50 L50 100 L0 50 Z',
                fill = changed and '#0000FFFF' or '#FF0000FF',
                animate = { duration = 2.5, curve = 'linear' } }
        end
        """)
        let start = CACurrentMediaTime()
        widget.surface.clock = { start }
        widget.render(ShellBarData())
        let renderer = try ShellLayerScene.engineQueue.sync {
            let root = widget.surface.scene.container
            root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
            root.speed = 0
            root.timeOffset = start
            return try ShellOffscreenRenderer(root: root, width: 100, height: 100)
        }
        let initial = try ShellLayerScene.engineQueue.sync { try renderer.render(paused: start) }
        XCTAssertEqual(initial[(20 * 100 + 20) * 4 + 3], 0)
        XCTAssertEqual(initial[(50 * 100 + 50) * 4 + 3], 255)

        widget.resources.motion.userAnimationsEnabled = true
        widget.set("seconds") { $0.number(1) }
        widget.render(ShellBarData())
        for fraction in [0.25, 0.5, 0.75, 1.04] {
            let pixels = try ShellLayerScene.engineQueue.sync {
                try renderer.render(paused: start + 2.5 * fraction)
            }
            XCTAssertEqual(pixels[(20 * 100 + 20) * 4 + 3], 0, "Outside the contour at \(fraction)")
            XCTAssertEqual(pixels[(50 * 100 + 50) * 4 + 3], 255, "Inside the contour at \(fraction)")
            let top = Int(25 * min(fraction, 1))
            XCTAssertEqual(pixels[((top - 3) * 100 + 50) * 4 + 3], 0, "Above the contour at \(fraction)")
            XCTAssertEqual(pixels[((top + 3) * 100 + 50) * 4 + 3], 255, "Below the contour at \(fraction)")
        }
    }
}
