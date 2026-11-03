// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

extension ShellVitreusVisualiserTests {
    func testNativeColumnsHavePixelsOnEveryEdgeAndCornerFanAtBothScales() throws {
        for placement in ["bottom", "corners", "top", "left", "right"] {
            let fixture = try fixture(settings: ["visualiser": .bool(true), "lay": .string(placement)])
            setBands(fixture.widget, Array(repeating: 0.8, count: 60))
            for scale in placement == "corners" ? [1, 2] : [1] {
                let bytes = try VitreusFixture.pixels(
                    fixture.widget,
                    crop: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    scale: scale
                )
                func alpha(_ x: Int, _ y: Int) -> UInt8 {
                    bytes[((y * scale) * 1512 * scale + x * scale) * 4 + 3]
                }
                XCTAssertEqual(alpha(756, 491), 0)
                switch placement {
                case "top": XCTAssertGreaterThan(alpha(756, 80), 50)
                case "left": XCTAssertGreaterThan(alpha(80, 491), 50)
                case "right": XCTAssertGreaterThan(alpha(1432, 491), 50)
                case "corners": XCTAssertGreaterThan(alpha(50, 932), 50)
                default: XCTAssertGreaterThan(alpha(756, 902), 50)
                }
                if scale == 1 { try saveVisualiser(bytes, width: 1512, height: 982, name: "visualiser-" + placement) }
            }
        }
    }

    func testFanSpringKeepsTheEmbeddedAnchorFixedAndActuallyPlaysAt84Milliseconds() throws {
        let fixture = try fixture(settings: ["visualiser": .bool(true), "lay": .string("corners")])
        let scene = fixture.widget.surface.scene
        let start = CACurrentMediaTime()
        let renderer = try ShellLayerScene.engineQueue.sync {
            scene.container.frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
            scene.container.isGeometryFlipped = true
            scene.container.speed = 0
            scene.container.timeOffset = start
            return try ShellOffscreenRenderer(root: scene.container, width: 1512, height: 982)
        }
        let initial = try ShellLayerScene.engineQueue.sync { try renderer.render(paused: start) }
        fixture.widget.resources.motion.userAnimationsEnabled = true
        fixture.widget.surface.refreshShaders()
        ShellLayerScene.engineQueue.sync {}
        setBands(fixture.widget, Array(repeating: 0.9, count: 60))
        try ShellLayerScene.engineQueue.sync {
            for binding in scene.spectrum.bindings.values {
                let layer = try XCTUnwrap(binding.targets.values.first?.first)
                let height = try motion(layer, channel: .height)
                let x = try motion(layer, channel: .x)
                let y = try motion(layer, channel: .y)
                XCTAssertEqual(x.beginTime, height.beginTime)
                XCTAssertEqual(y.beginTime, height.beginTime)
                XCTAssertNil(layer.animation(forKey: ShellGlassBody.Channel.transform.key))
                let elapsed = 0.084
                let direction = CGPoint(x: sin(binding.base.rotation), y: -cos(binding.base.rotation))
                let base = CGPoint(
                    x: binding.base.rect.midX - direction.x * binding.base.rect.height / 2,
                    y: binding.base.rect.midY - direction.y * binding.base.rect.height / 2
                )
                XCTAssertEqual(
                    try sample(x, elapsed) - direction.x * sample(height, elapsed) / 2,
                    base.x,
                    accuracy: 0.001
                )
                XCTAssertEqual(
                    try sample(y, elapsed) - direction.y * sample(height, elapsed) / 2,
                    base.y,
                    accuracy: 0.001
                )
            }
            _ = try renderer.render(paused: start)
            let frame = try renderer.render(paused: start + 0.084)
            let before = stride(from: 3, to: initial.count, by: 4).count { initial[$0] > 50 }
            let after = stride(from: 3, to: frame.count, by: 4).count { frame[$0] > 50 }
            XCTAssertGreaterThan(after, before)
            try saveVisualiser(frame, width: 1512, height: 982, name: "visualiser-corners-84ms")
        }
    }

    private func motion(_ layer: CALayer, channel: ShellGlassBody.Channel) throws -> CASpringAnimation {
        try XCTUnwrap(layer.animation(forKey: channel.key) as? CASpringAnimation)
    }

    private func sample(_ animation: CASpringAnimation, _ elapsed: Double) throws -> Double {
        let from = try XCTUnwrap(animation.fromValue as? NSNumber).doubleValue
        let to = try XCTUnwrap(animation.toValue as? NSNumber).doubleValue
        return to + ShellSpringDynamics.position(
            at: elapsed,
            displacement: from - to,
            initialVelocity: animation.initialVelocity * (to - from),
            spring: .init(
                mass: animation.mass,
                stiffness: animation.stiffness,
                damping: animation.damping
            )
        )
    }

    private func saveVisualiser(_ bytes: [UInt8], width: Int, height: Int, name: String) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Little
                .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst
                        .rawValue)),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        try ShellVitreusDeskTests.write(image, name: name)
    }
}
