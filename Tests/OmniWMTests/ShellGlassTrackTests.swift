// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

private struct GlassTrackFixture {
    let root: CALayer
    let body: ShellGlassBody
    let renderer: ShellOffscreenRenderer
    let begin: CFTimeInterval
}

@MainActor
final class ShellGlassTrackTests: XCTestCase {
    private func fixture(
        _ shape: ShellGlassShape, native: Bool = true, additional: [ShellGlassShape] = [],
        fillAlpha: CGFloat = 1, size: Int = 256
    ) throws -> GlassTrackFixture {
        let root = CALayer()
        let begin = CACurrentMediaTime()
        root.frame = CGRect(x: 0, y: 0, width: size, height: size)
        root.isGeometryFlipped = true
        root.speed = 0
        root.timeOffset = begin
        let paint = ShellLayerPaint(
            fill: CGColor(gray: 1, alpha: fillAlpha), border: nil, borderWidth: 0, radius: 0,
            opacity: 1, scale: 1, shadow: CGColor(gray: 0, alpha: 0), shadowRadius: 0,
            blurRadius: 0, saturation: 1
        )
        let recipe = try XCTUnwrap(ShellGlassRecipe("glass:\(shape.kind == 2 ? 8 : 0):-1:0:0:0"))
        return try ShellLayerScene.engineQueue.sync {
            let body = ShellGlassBody(forceFallback: !native)
            root.addSublayer(body.layer)
            let renderer = try ShellOffscreenRenderer(root: root, width: size, height: size)
            body.apply(
                size: root.bounds.size,
                shapes: [shape] + additional,
                recipe: recipe,
                paint: paint,
                animation: nil
            )
            if native {
                guard ShellGlassCapability.shared.available else {
                    throw XCTSkip(body.failure ?? "Native glass is unavailable")
                }
                XCTAssertTrue(body.nativeAvailable, body.failure ?? "Native fixture geometry was rejected")
                guard body.nativeAvailable else {
                    throw ShellScriptFailure(
                        kind: .runtime,
                        message: body.failure ?? "Native fixture geometry was rejected"
                    )
                }
                for index in [0, 2, 3] { body.sdfLayers[index].isHidden = true }
            }
            return GlassTrackFixture(root: root, body: body, renderer: renderer, begin: begin)
        }
    }

    private nonisolated static func animate(
        _ fixture: GlassTrackFixture, samples: [ShellGlassBody.TrackSample], duration: Double
    ) -> [ShellRevealAnimation] {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let plan = fixture.body.trackAnimations(samples, begin: fixture.begin, duration: duration)
        for item in plan.items { item.layer.add(item.animation, forKey: item.key) }
        return plan.items
    }

    private nonisolated static func ellipse(at time: Double) -> ShellGlassShape {
        let q = time / 0.4
        return ShellGlassShape(
            slot: 1, kind: 1,
            rect: CGRect(x: 80 - 20 * q, y: 80 - 10 * q, width: 80 + 40 * q, height: 30 + 20 * q),
            radius: 0, thickness: 0, rotation: 0.6 * q
        )
    }

    private nonisolated static func frame(at time: Double, slot: Int32 = 1) -> ShellGlassShape {
        let q = time / 0.4
        return ShellGlassShape(
            slot: slot, kind: 2,
            rect: CGRect(x: -64 - 8 * q, y: -64 - 8 * q, width: 224 + 16 * q, height: 224 + 16 * q),
            radius: 88 + 8 * q, thickness: 72 + 16 * q
        )
    }

    private nonisolated static func bounds(_ pixels: [UInt8]) throws -> CGRect {
        var left = 256, right = -1, top = 256, bottom = -1
        for y in 0 ..< 256 {
            for x in 0 ..< 256 where pixels[(y * 256 + x) * 4 + 3] >= 128 {
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        XCTAssertGreaterThanOrEqual(right, left)
        guard right >= left else { throw ShellScriptFailure(kind: .runtime, message: "The glass track rendered empty") }
        return CGRect(x: left, y: top, width: right + 1 - left, height: bottom + 1 - top)
    }

    func testNativeEllipseCompositeFollowsSampledSizeRotationAndPositionAt84Milliseconds() throws {
        let fixture = try fixture(Self.ellipse(at: 0.4))
        try ShellLayerScene.engineQueue.sync {
            let samples = (0 ... 48).map { index in
                let time = Double(index) / 120
                return ShellGlassBody.TrackSample(time: time, shape: Self.ellipse(at: time))
            }
            let items = Self.animate(fixture, samples: samples, duration: 0.4)
            XCTAssertEqual(items.count, 20)
            for item in items {
                let animation = try XCTUnwrap(item.layer.animation(forKey: item.key) as? CAKeyframeAnimation)
                XCTAssertEqual(animation.duration, 0.4)
                XCTAssertEqual(animation.values?.count, 49)
                XCTAssertEqual(animation.beginTime, fixture.begin, accuracy: 1e-6)
                XCTAssertNil(item.layer.animation(forKey: ShellGlassBody.Channel.transform.key))
            }
            for time in [0.084, 0.13, 0.4] {
                let pixels = try fixture.renderer.render(paused: fixture.begin + time)
                let actual = try Self.bounds(pixels)
                let shape = Self.ellipse(at: time)
                let rx = shape.rect.width / 2, ry = shape.rect.height / 2
                let sine = sin(shape.rotation), cosine = cos(shape.rotation)
                let extentX = sqrt(rx * rx * cosine * cosine + ry * ry * sine * sine)
                let extentY = sqrt(rx * rx * sine * sine + ry * ry * cosine * cosine)
                for (value, expected) in [
                    (actual.minX, shape.rect.midX - extentX), (actual.maxX, shape.rect.midX + extentX),
                    (actual.minY, shape.rect.midY - extentY), (actual.maxY, shape.rect.midY + extentY)
                ] {
                    XCTAssertEqual(value, expected, accuracy: 1, "\(time)")
                }
            }
        }
    }

    func testFrameTracksItsHoleAllMaskPartsAndRoundedContainer() throws {
        let native = try fixture(Self.frame(at: 0.4), size: 96)
        let fallback = try fixture(Self.frame(at: 0.4), native: false, size: 96)
        let glass = try fixture(Self.frame(at: 0.4), fillAlpha: 0.36, size: 96)
        try ShellLayerScene.engineQueue.sync {
            let baseline = try native.renderer.render(paused: native.begin)
            XCTAssertEqual(baseline[(48 * 96 + 48) * 4 + 3], 0, "The static native frame hole must be clear")
            let glassBaseline = try glass.renderer.render(paused: glass.begin)
            XCTAssertEqual(
                glassBaseline[(48 * 96 + 48) * 4 + 3],
                0,
                "The static translucent frame hole must be clear"
            )
            let samples = (0 ... 48).map { index in
                let time = Double(index) / 120
                return ShellGlassBody.TrackSample(time: time, shape: Self.frame(at: time))
            }
            let items = Self.animate(native, samples: samples, duration: 0.4)
            _ = Self.animate(fallback, samples: samples, duration: 0.4)
            XCTAssertEqual(native.body.trackLayers(1).count, 11)
            XCTAssertEqual(items.count, 68)
            for time in [0.084, 0.13, 0.4] {
                let sdf = try native.renderer.render(paused: native.begin + time)
                let mask = try fallback.renderer.render(paused: fallback.begin + time)
                let shape = Self.frame(at: time)
                let hole = shape.rect.insetBy(dx: shape.thickness, dy: shape.thickness)
                let radius = shape.radius - shape.thickness
                XCTAssertEqual(sdf[(48 * 96 + 48) * 4 + 3], 0)
                XCTAssertEqual(mask[(48 * 96 + 48) * 4 + 3], 0)
                for y in [16, 24, 40, 48, 55, 64, 71, 79] {
                    let sdfEdge = (0 ..< 48).first { sdf[(y * 96 + $0) * 4 + 3] < 128 }
                    let maskEdge = (0 ..< 48).first { mask[(y * 96 + $0) * 4 + 3] < 128 }
                    let actual = try XCTUnwrap(sdfEdge)
                    XCTAssertEqual(Double(actual), Double(try XCTUnwrap(maskEdge)), accuracy: 1, "\(time), y=\(y)")
                    let dy = max(0, abs(Double(y) + 0.5 - hole.midY) - hole.height / 2 + radius)
                    let inset = radius - sqrt(max(0, radius * radius - dy * dy))
                    XCTAssertEqual(Double(actual), hole.minX + inset, accuracy: 1, "\(time), y=\(y)")
                }
            }
        }
    }

    func testRekeyAndModelRestorePreserveLayerIdentityOrderAndRunningTracks() throws {
        let fixture = try fixture(Self.frame(at: 0.4), size: 96)
        try ShellLayerScene.engineQueue.sync {
            let samples = [
                ShellGlassBody.TrackSample(time: 0, shape: Self.frame(at: 0)),
                ShellGlassBody.TrackSample(time: 0.4, shape: Self.frame(at: 0.4))
            ]
            let items = Self.animate(fixture, samples: samples, duration: 0.4)
            let original = fixture.body.trackLayers(1).values.flatMap { $0 }.map(ObjectIdentifier.init)
            let order = fixture.body.sdfLayers.map { ($0.sublayers ?? []).map(ObjectIdentifier.init) }
            fixture.body.rekeyShape(from: 1, to: Int32.max)
            XCTAssertTrue(fixture.body.trackLayers(1).isEmpty)
            let moved = fixture.body.trackLayers(Int32.max).values.flatMap { $0 }.map(ObjectIdentifier.init)
            XCTAssertEqual(Set(moved), Set(original))
            XCTAssertEqual(fixture.body.sdfLayers.map { ($0.sublayers ?? []).map(ObjectIdentifier.init) }, order)
            fixture.body.setTrackGeometry(Self.frame(at: 0.13, slot: Int32.max))
            for item in items {
                let animation = try XCTUnwrap(item.layer.animation(forKey: item.key) as? CAKeyframeAnimation)
                XCTAssertEqual(animation.duration, 0.4)
                XCTAssertEqual(animation.beginTime, fixture.begin, accuracy: 1e-6)
                XCTAssertEqual(animation.values?.count, 2)
            }
            fixture.body.removeTrack(Int32.max)
            for item in items { XCTAssertNil(item.layer.animation(forKey: item.key)) }
            let container = try XCTUnwrap(fixture.body.maskContainers[Int32.max])
            XCTAssertEqual(container.position, Self.frame(at: 0.13).rect.origin)
        }
    }

    func testDegenerateEllipseEndpointHasOnlyFiniteCompositeValues() throws {
        let fixture = try fixture(Self.ellipse(at: 0.4))
        try ShellLayerScene.engineQueue.sync {
            let empty = ShellGlassShape(
                slot: 1, kind: 1, rect: CGRect(x: 120, y: 95, width: 0, height: 0), radius: 0, thickness: 0
            )
            let samples = [
                ShellGlassBody.TrackSample(time: 0, shape: Self.ellipse(at: 0.4)),
                ShellGlassBody.TrackSample(time: 0.4, shape: empty)
            ]
            let items = Self.animate(fixture, samples: samples, duration: 0.4)
            XCTAssertEqual(items.count, 20)
            for item in items where item.key == "omni.glass.transform" {
                let animation = try XCTUnwrap(item.animation as? CAKeyframeAnimation)
                let transform = try XCTUnwrap(animation.values?.last as? NSValue).caTransform3DValue
                XCTAssertTrue([transform.m11, transform.m12, transform.m21, transform.m22, transform.m41, transform.m42]
                    .allSatisfy(\.isFinite))
            }
            let pixels = try fixture.renderer.render(paused: fixture.begin + 0.401)
            XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 0 })
        }
    }

    func testRemovingOneShapePreservesOtherLayersOrderAndSprings() throws {
        let other = ShellGlassShape(
            slot: 2, kind: 0, rect: CGRect(x: 80, y: 100, width: 40, height: 20), radius: 5, thickness: 0
        )
        let fixture = try fixture(Self.frame(at: 0.4), additional: [other], size: 96)
        try ShellLayerScene.engineQueue.sync {
            let layers = fixture.body.trackLayers(2).values.flatMap { $0 }
            let order = fixture.body.sdfLayers.map { ($0.sublayers ?? []).filter { layers.contains($0) } }
            for layer in layers {
                let spring = CASpringAnimation(keyPath: "position.x")
                spring.fromValue = 80
                spring.toValue = 140
                spring.duration = 1
                spring.beginTime = fixture.begin
                layer.add(spring, forKey: ShellGlassBody.Channel.x.key)
            }
            fixture.body.removeShape(1)
            XCTAssertTrue(fixture.body.trackLayers(1).isEmpty)
            XCTAssertNil(fixture.body.maskContainers[1])
            XCTAssertEqual(
                Set(fixture.body.trackLayers(2).values.flatMap { $0 }.map(ObjectIdentifier.init)),
                Set(layers.map(ObjectIdentifier.init))
            )
            XCTAssertEqual(fixture.body.sdfLayers.map { ($0.sublayers ?? []) }, order)
            for layer in layers {
                let spring = try XCTUnwrap(layer.animation(forKey: ShellGlassBody.Channel.x.key) as? CASpringAnimation)
                XCTAssertEqual(spring.fromValue as? Int, 80)
                XCTAssertEqual(spring.toValue as? Int, 140)
                XCTAssertEqual(spring.beginTime, fixture.begin)
            }
        }
    }
}
