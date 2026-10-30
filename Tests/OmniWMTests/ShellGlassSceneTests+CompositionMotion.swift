// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

extension ShellGlassSceneTests {
    func testVariableAlphaMaskJoinsAnAlreadyRunningCanvasSpring() throws {
        try ShellLayerScene.engineQueue.sync {
            let body = ShellGlassBody()
            var paint = ShellLayerPaint(
                fill: Self.rimTint.copy(alpha: 0.5), border: nil, borderWidth: 0, radius: 0, opacity: 1, scale: 1,
                shadow: ShellLayerScene.clear, shadowRadius: 0
            )
            let recipe = try XCTUnwrap(ShellGlassRecipe("glass:26:-1:0:0:0|optics:0.4:1:90"))
            func apply(_ side: CGFloat, _ animation: ShellAnimation?) {
                let rect = CGRect(x: 0, y: 0, width: side, height: side)
                body.apply(
                    size: rect.size,
                    shapes: [.init(slot: 1, kind: 0, rect: rect, radius: 0, thickness: 0)],
                    recipe: recipe,
                    paint: paint,
                    animation: animation,
                    shapeAnimations: animation.map { [1: $0] }
                )
            }
            apply(96, nil)
            let root = CALayer()
            root.frame = CGRect(x: 0, y: 0, width: 96, height: 96)
            root.isGeometryFlipped = true
            root.addSublayer(body.layer)
            let renderer = try ShellOffscreenRenderer(root: root, width: 96, height: 96)
            _ = try renderer.render(paused: CACurrentMediaTime())
            apply(48, Self.calm)
            paint.gradient = [
                CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.2),
                CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.8)
            ]
            apply(48, nil)
            let band = try XCTUnwrap(body.canvasLayers.first { $0.compositingFilter != nil })
            let alpha = try XCTUnwrap(band.superlayer?.mask as? CAGradientLayer)
            let key = ShellGlassBody.Channel.width.key
            let mask = try XCTUnwrap(alpha.animation(forKey: key) as? CASpringAnimation)
            let lead = try XCTUnwrap(body.sdfLayers[1].animation(forKey: key) as? CASpringAnimation)
            XCTAssertEqual(mask.beginTime, lead.beginTime)
            XCTAssertEqual(mask.fromValue as? NSNumber, lead.fromValue as? NSNumber)
            let pixels = try renderer.render(paused: lead.beginTime + 0.03)
            let edge = try XCTUnwrap((0 ..< 96).last { pixels[(20 * 96 + $0) * 4 + 3] > 40 })
            XCTAssertGreaterThan(edge, 80)
        }
    }

    func testComposedMaterialTransitionsRestoreTintGradientAndBackdropWithoutRetainingOldMasks() throws {
        try ShellLayerScene.engineQueue.sync {
            let live = ShellGlassBody()
            for transition in Self.compositionTransitions {
                let optics = transition.optics, colors = transition.colors, fill = transition.fill
                let reference = try Self.rimBody(optics, fill: fill, gradient: colors)
                _ = try Self.rimBody(optics, fill: fill, gradient: colors, into: live)
                XCTAssertEqual(live.elements.count, reference.elements.count)
                XCTAssertEqual(live.layer.sublayers?.count, reference.layer.sublayers?.count)
                let expected = try Self.pixels(reference.layer, width: 192, height: 192, scale: 2)
                let actual = try Self.pixels(live.layer, width: 192, height: 192, scale: 2)
                var color = 0, alpha = 0
                for pixel in stride(from: 0, to: actual.count, by: 4) {
                    alpha = max(alpha, abs(Int(actual[pixel + 3]) - Int(expected[pixel + 3])))
                    for channel in 0 ..< 3 { color = max(
                        color,
                        abs(Int(actual[pixel + channel]) - Int(expected[pixel + channel]))
                    ) }
                    XCTAssertLessThanOrEqual(actual[pixel ..< pixel + 3].max() ?? 0, actual[pixel + 3])
                }
                XCTAssertLessThanOrEqual(color, 3)
                XCTAssertLessThanOrEqual(alpha, 1)
            }
        }
    }

    private struct CompositionTransition {
        let optics: String
        let colors: [CGColor]?
        let fill: CGColor
    }

    private nonisolated static var compositionTransitions: [CompositionTransition] {
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5)
        let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.75)
        return [
            .init(optics: "0.4:1:90", colors: nil, fill: rimTint),
            .init(optics: "0.4:1:90", colors: [red, red], fill: rimTint),
            .init(optics: "0.4:1:90", colors: [red, blue], fill: rimTint),
            .init(optics: "0.1:0:90", colors: nil, fill: rimTint),
            .init(optics: "0.4:1:90", colors: nil, fill: red),
            .init(optics: "0:1:90", colors: [red, blue], fill: rimTint),
            .init(optics: "0.4:1:90", colors: [blue, blue], fill: rimTint),
            .init(optics: "0.1:0:90", colors: nil, fill: rimTint)
        ]
    }
}
