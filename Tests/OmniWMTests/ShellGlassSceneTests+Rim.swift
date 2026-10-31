// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
extension ShellGlassSceneTests {
    nonisolated static let rimTint = CGColor(srgbRed: 0x1B / 255, green: 0x21 / 255, blue: 0x27 / 255, alpha: 1)
    nonisolated static let rimShape = ShellGlassShape(
        slot: 1, kind: 0, rect: CGRect(x: 16, y: 16, width: 64, height: 64), radius: 12, thickness: 0
    )

    nonisolated static func smoothstep(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let progress = min(max((value - low) / (high - low), 0), 1)
        return progress * progress * (3 - 2 * progress)
    }

    nonisolated static func rimBody(
        _ optics: String,
        fill: CGColor = rimTint,
        gradient: [CGColor]? = nil,
        shapes: [ShellGlassShape] = [rimShape],
        into body: ShellGlassBody = ShellGlassBody()
    ) throws -> ShellGlassBody {
        var paint = ShellLayerPaint(
            fill: fill, border: nil, borderWidth: 0, radius: 0, opacity: 1, scale: 1, shadow: nil, shadowRadius: 6
        )
        paint.gradient = gradient
        body.apply(
            size: CGSize(width: 96, height: 96),
            shapes: shapes,
            recipe: try XCTUnwrap(ShellGlassRecipe("glass:26:-1:0:0:1|optics:\(optics)")),
            paint: paint,
            animation: nil
        )
        return try native(body)
    }

    nonisolated static func edgeIndex(_ edge: Int, depth: Int, scale: Int) -> Int {
        let width = 96 * scale
        let middle = 48 * scale
        let (x, y) = switch edge {
        case 0: (16 * scale + depth, middle)
        case 1: (80 * scale - 1 - depth, middle)
        case 2: (middle, 16 * scale + depth)
        default: (middle, 80 * scale - 1 - depth)
        }
        return (y * width + x) * 4
    }

    nonisolated static func lightness(_ pixels: [UInt8], _ index: Int) -> Double {
        0.0722 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.2126 * Double(pixels[index + 2])
    }

    nonisolated static func pleamarBand(_ amount: Double, base: [UInt8], index: Int, depth: Int, scale: Int) -> Double {
        let distance = -(Double(depth) + 0.5) / Double(scale)
        let reach = 0.75 / Double(scale)
        let light = 255 * amount * smoothstep(-2.2, -0.4, distance) * (1 - smoothstep(-reach, reach, distance))
        let added = (0 ..< 3).map { min(255 - Double(base[index + $0]), light) }
        return 0.0722 * added[0] + 0.7152 * added[1] + 0.2126 * added[2]
    }

    nonisolated static func assertPleamarBand(
        _ lit: [UInt8], over base: [UInt8], amount: Double, scale: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let depths = Array(0 ..< 6 * scale)
        let reference = depths.map { pleamarBand(
            amount,
            base: base,
            index: edgeIndex(0, depth: $0, scale: scale),
            depth: $0,
            scale: scale
        ) }
        let peak = reference.max() ?? 0
        XCTAssertGreaterThan(peak, 4, file: file, line: line)
        var first: [Double]?
        for edge in 0 ..< 4 {
            let outside = edgeIndex(edge, depth: -1, scale: scale)
            XCTAssertEqual(lit[outside + 3], base[outside + 3], "edge \(edge) halo", file: file, line: line)
            let profile = depths.map { lightness(lit, edgeIndex(edge, depth: $0, scale: scale)) - lightness(
                base,
                edgeIndex(edge, depth: $0, scale: scale)
            ) }
            for (depth, (value, expected)) in zip(depths, zip(profile, reference)) {
                let tolerance = depth >= 3 * scale ? 1 : 0.15 * peak
                XCTAssertEqual(
                    value,
                    expected,
                    accuracy: tolerance,
                    "edge \(edge) depth \(depth) \(profile) vs \(reference)",
                    file: file,
                    line: line
                )
            }
            let sum = profile.reduce(0, +) / reference.reduce(0, +)
            XCTAssertEqual(sum, 1, accuracy: 0.15, "edge \(edge) sum", file: file, line: line)
            if let first {
                for (value, other) in zip(profile, first) { XCTAssertEqual(
                    value,
                    other,
                    accuracy: 1,
                    "edge \(edge) uniform",
                    file: file,
                    line: line
                ) }
            } else {
                first = profile
            }
        }
    }

    func testFlatRimIsAUniformPleamarBandWithoutShine() throws {
        let grey = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        try ShellLayerScene.engineQueue.sync {
            for gradient in [nil, [grey, grey]] {
                for scale in [1, 2] {
                    let size = 96 * scale
                    let plain = try Self.pixels(
                        Self.rimBody("0:1:90", gradient: gradient).layer,
                        width: size,
                        height: size,
                        scale: scale
                    )
                    let row = (16 * scale ..< 80 * scale)
                        .map { Self.luminance(plain, x: $0, y: 48 * scale, width: size) }
                    XCTAssertLessThanOrEqual(row.map { abs($0 - row[row.count / 2]) }.max() ?? 0, 1)
                    for rim in [0.1, 0.3, 0.4, 0.55] {
                        let body = try Self.rimBody("\(rim):1:90", gradient: gradient)
                        XCTAssertEqual(body.sdfLayers[2].opacity, 0)
                        XCTAssertEqual(body.sdfLayers[3].opacity, 0)
                        let lit = try Self.pixels(body.layer, width: size, height: size, scale: scale)
                        Self.assertPleamarBand(lit, over: plain, amount: rim, scale: scale)
                        let shadow = (82 * scale ... 86 * scale).map { lit[($0 * size + 48 * scale) * 4 + 3] }
                        XCTAssertGreaterThan(shadow[0], shadow[shadow.count - 1])
                        XCTAssertGreaterThan(shadow[shadow.count - 1], 0)
                    }
                }
            }
        }
    }

    func testGlassRimKeepsFittedShineAndAddsSharedBandAboveFittedRim() throws {
        let tint = Self.rimTint.copy(alpha: 0.36) ?? Self.rimTint
        try ShellLayerScene.engineQueue.sync {
            for scale in [1, 2] {
                let size = 96 * scale
                let fitted = try Self.rimBody("0.1:0:90", fill: tint)
                XCTAssertEqual(fitted.elements.count, 4)
                let shine = try Self.pixels(fitted.layer, width: size, height: size, scale: scale)
                XCTAssertEqual(
                    try Self.pixels(Self.rimBody("0:0:90", fill: tint).layer, width: size, height: size, scale: scale),
                    shine
                )
                let lit = (0 ..< 3).map { Self.lightness(shine, Self.edgeIndex(0, depth: $0 * scale, scale: scale)) }
                let unlit = (0 ..< 3).map { Self.lightness(shine, Self.edgeIndex(2, depth: $0 * scale, scale: scale)) }
                XCTAssertGreaterThan(lit.reduce(0, +), unlit.reduce(0, +) + 40)
                for rim in [0.3, 0.4, 0.55] {
                    let body = try Self.rimBody("\(rim):0:90", fill: tint)
                    let banded = try Self.pixels(body.layer, width: size, height: size, scale: scale)
                    for edge in 0 ..< 4 {
                        let index = Self.edgeIndex(edge, depth: 0, scale: scale)
                        XCTAssertGreaterThan(Self.lightness(banded, index), min(Self.lightness(shine, index), 250))
                    }
                    for layer in [body.sdfLayers[2], body.sdfLayers[3], fitted.sdfLayers[2], fitted.sdfLayers[3]] {
                        layer.isHidden = true
                    }
                    Self.assertPleamarBand(
                        try Self.pixels(body.layer, width: size, height: size, scale: scale),
                        over: try Self.pixels(fitted.layer, width: size, height: size, scale: scale),
                        amount: 0.36 * (rim - 0.1),
                        scale: scale
                    )
                    for layer in [fitted.sdfLayers[2], fitted.sdfLayers[3]] { layer.isHidden = false }
                }
            }
        }
    }

    func testRimBandKeepsPremultipliedPixelsValidUpToFullRim() throws {
        let mint = [
            CGColor(srgbRed: 0xDC / 255, green: 0xF8 / 255, blue: 0xEC / 255, alpha: 1),
            CGColor(srgbRed: 0x6C / 255, green: 0xBC / 255, blue: 0x9C / 255, alpha: 1)
        ]
        let fractional = ShellGlassShape(
            slot: 1, kind: 0, rect: CGRect(x: 16.3, y: 15.6, width: 63.5, height: 40.2), radius: 9.7, thickness: 0
        )
        let union = [
            ShellGlassShape(
                slot: 1,
                kind: 0,
                rect: CGRect(x: 14, y: 20, width: 40, height: 30),
                radius: 8,
                thickness: 0
            ),
            ShellGlassShape(
                slot: 2,
                kind: 1,
                rect: CGRect(x: 44, y: 34, width: 36, height: 44),
                radius: 0,
                thickness: 0
            )
        ]
        let glassTint = Self.rimTint.copy(alpha: 0.36) ?? Self.rimTint
        let kinds: [(flat: Int, gradient: [CGColor]?)] = [(1, nil), (0, nil), (1, mint)]
        try ShellLayerScene.engineQueue.sync {
            var renders = 0
            for kind in kinds {
                let fill = kind.flat == 1 ? Self.rimTint : glassTint
                for (index, rim) in [0.1, 0.4, 0.55, 0.7, 1.0].enumerated() {
                    for scale in [1, 2] where Self.fullSweep || scale == index % 2 + 1 {
                        let size = 96 * scale
                        let repeats = Array(repeating: [Self.rimShape], count: Self.fullSweep ? 8 : 2)
                        for shapes in repeats + [[fractional], union] {
                            let body = try Self.rimBody(
                                "\(rim):\(kind.flat):90", fill: fill, gradient: kind.gradient, shapes: shapes
                            )
                            let pixels = try Self.pixels(body.layer, width: size, height: size, scale: scale)
                            let invalid = stride(from: 0, to: pixels.count, by: 4).count {
                                max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) > pixels[$0 + 3]
                            }
                            XCTAssertEqual(invalid, 0, "rim \(rim) flat \(kind.flat) \(scale)x \(shapes.count) shapes")
                            renders += 1
                        }
                    }
                }
            }
            XCTAssertEqual(renders, Self.fullSweep ? 300 : 60)
        }
    }

    func testBandLayerSitsAboveFillOnlyWhileRimAddsLight() throws {
        try ShellLayerScene.engineQueue.sync {
            guard ShellGlassCapability.shared.available else { throw XCTSkip("Native glass is unavailable") }
            let fitted = try Self.rimBody("0.1:0:90")
            XCTAssertEqual(fitted.layer.sublayers?.count, 6)
            let glass = try Self.rimBody("0.3:0:90")
            let band = try XCTUnwrap(glass.canvasLayers.first { $0.compositingFilter != nil })
            let group = try XCTUnwrap(band.superlayer)
            XCTAssertTrue(group.mask === glass.sdfLayers[1])
            XCTAssertTrue(group.superlayer === glass.layer)
            XCTAssertNotNil(band.compositingFilter)
            let effect = try XCTUnwrap(band.value(forKey: "effect") as? NSObject)
            XCTAssertEqual(NSStringFromClass(type(of: effect)), "CASDFGradientEffect")
            let colors = try XCTUnwrap(effect.value(forKey: "colors") as? [CGColor])
            XCTAssertEqual(try XCTUnwrap(colors.last).alpha, 0.36 * 0.2, accuracy: 1e-6)
            XCTAssertEqual(glass.elements.count, 5)
            XCTAssertTrue(glass.canvasLayers.contains { $0 === band })
        }
    }

    func testRimChangesOnALiveUnionBodyRenderLikeAFreshBody() throws {
        let union = [
            ShellGlassShape(
                slot: 1,
                kind: 0,
                rect: CGRect(x: 14, y: 20, width: 40, height: 30),
                radius: 8,
                thickness: 0
            ),
            ShellGlassShape(
                slot: 2,
                kind: 1,
                rect: CGRect(x: 44, y: 34, width: 36, height: 44),
                radius: 0,
                thickness: 0
            )
        ]
        try ShellLayerScene.engineQueue.sync {
            for flat in [1, 0] {
                let live = try Self.rimBody("0:\(flat):90", shapes: union)
                for rim in [0.4, 0.55] {
                    _ = try Self.rimBody("\(rim):\(flat):90", shapes: union, into: live)
                    let fresh = try Self.rimBody("\(rim):\(flat):90", shapes: union)
                    XCTAssertEqual(
                        try Self.pixels(live.layer, width: 192, height: 192, scale: 2),
                        try Self.pixels(fresh.layer, width: 192, height: 192, scale: 2),
                        "rim \(rim) flat \(flat)"
                    )
                }
            }
        }
    }

    func testBandJoinsRunningMotionWhenRimTurnsOnAndLeavesWhenItTurnsOff() throws {
        try ShellLayerScene.engineQueue.sync {
            guard ShellGlassCapability.shared.available else { throw XCTSkip("Native glass is unavailable") }
            let body = ShellGlassBody()
            let root = CALayer()
            root.frame = CGRect(x: 0, y: 0, width: 96, height: 96)
            root.isGeometryFlipped = true
            root.addSublayer(body.layer)
            let paint = ShellLayerPaint(
                fill: Self.rimTint, border: nil, borderWidth: 0, radius: 0, opacity: 1, scale: 1,
                shadow: ShellLayerScene.clear, shadowRadius: 0
            )
            func apply(_ side: CGFloat, rim: Double, _ animation: ShellAnimation?) throws {
                let rect = CGRect(x: 0, y: 0, width: side, height: side)
                body.apply(
                    size: rect.size,
                    shapes: [ShellGlassShape(slot: 1, kind: 0, rect: rect, radius: 0, thickness: 0)],
                    recipe: try XCTUnwrap(ShellGlassRecipe("glass:26:-1:0:0:1|optics:\(rim):1:90")),
                    paint: paint,
                    animation: animation,
                    shapeAnimations: animation.map { [1: $0] }
                )
            }
            try apply(96, rim: 0, nil)
            XCTAssertEqual(body.elements.count, 4)
            XCTAssertEqual(body.layer.sublayers?.count, 5)
            let renderer = try ShellOffscreenRenderer(root: root, width: 96, height: 96)
            _ = try renderer.render(paused: CACurrentMediaTime())
            try apply(48, rim: 0, Self.calm)
            try apply(48, rim: 0.4, nil)
            XCTAssertEqual(body.elements.count, 5)
            let key = ShellGlassBody.ElementKey(slot: 1, part: 0)
            let width = ShellGlassBody.Channel.width.key
            let leader = try XCTUnwrap(body.elements[1][key]?.animation(forKey: width) as? CASpringAnimation)
            let follower = try XCTUnwrap(body.elements[4][key]?.animation(forKey: width) as? CASpringAnimation)
            XCTAssertEqual(follower.beginTime, leader.beginTime)
            XCTAssertEqual(follower.fromValue as? NSNumber, leader.fromValue as? NSNumber)
            let canvas = try XCTUnwrap(body.sdfLayers[1].animation(forKey: width) as? CASpringAnimation)
            let bandCanvas = try XCTUnwrap(body.canvasLayers.first { $0.compositingFilter != nil }?
                .animation(forKey: width) as? CASpringAnimation)
            XCTAssertEqual(bandCanvas.beginTime, canvas.beginTime)
            let pixels = try renderer.render(paused: leader.beginTime + 0.03)
            let row = (0 ..< 96).map { Self.luminance(pixels, x: $0, y: 20) }
            let edge = try XCTUnwrap((0 ..< 96).last { pixels[(20 * 96 + $0) * 4 + 3] > 200 })
            XCTAssertGreaterThan(edge, 80)
            XCTAssertGreaterThan(row[edge], row[edge - 6] + 40)
            XCTAssertLessThan(abs(row[47] - row[edge - 6]), 2)
            try apply(48, rim: 0, nil)
            XCTAssertEqual(body.elements.count, 4)
            XCTAssertEqual(body.layer.sublayers?.count, 5)
        }
    }
}
