// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
extension ShellGlassSceneTests {
    func testGeometrySpringAnimatesSDFAndBaseMaskWithoutAFrameDriver() async throws {
        let scene = scene()
        await apply(initialCommands(), to: scene)
        try ShellLayerScene.engineQueue.sync {
            let renderer = try ShellOffscreenRenderer(root: scene.container, width: 96, height: 96)
            func edge(at time: Double, name: String) throws -> Int {
                let bytes = try renderer.render(paused: time)
                try Self.save(bytes, width: 96, name: name)
                return try XCTUnwrap((8 ... 55).max { bytes[(48 * 96 + $0) * 4 + 2] < bytes[(48 * 96 + $1) * 4 + 2] })
            }
            XCTAssertEqual(try edge(at: CACurrentMediaTime(), name: "animation-before.png"), 16)
            let animation = ShellAnimation(motion: .spring, speed: 1)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scene.applyFrame(1, CGRect(x: 40, y: 16, width: 40, height: 64), preset: animation, animated: true)
            scene.flushGlass(animated: true)
            let body = try Self.native(scene.glassBodies[0])
            let key = ShellGlassBody.ElementKey(slot: 1, part: 0)
            let element = try XCTUnwrap(body.elements[1][key])
            let mask = try XCTUnwrap(body.maskElements[key])
            var start: Double = 0
            var duration: Double = 0
            for target in [element, mask] {
                XCTAssertNil(target.animation(forKey: ShellGlassBody.Channel.y.key))
                let raw = try XCTUnwrap(target.animation(forKey: ShellGlassBody.Channel.x.key))
                let position = try XCTUnwrap(raw as? CASpringAnimation)
                XCTAssertEqual((position.fromValue as? NSNumber)?.doubleValue, 16)
                XCTAssertEqual((position.toValue as? NSNumber)?.doubleValue, 40)
                XCTAssertEqual(position.initialVelocity, 0)
                XCTAssertGreaterThan(position.duration, 0)
                XCTAssertGreaterThan(position.beginTime, 0)
                start = position.beginTime
                duration = position.duration
                XCTAssertEqual(target.bounds.size, CGSize(width: 40, height: 64))
            }
            CATransaction.commit()
            let initial = try edge(at: start + 0.001, name: "animation-start.png")
            let middle = try edge(at: start + duration * 0.12, name: "animation-middle.png")
            let settled = try edge(at: start + duration + 0.01, name: "animation-settled.png")
            XCTAssertLessThan(initial, middle)
            XCTAssertLessThan(middle, settled)
            XCTAssertEqual(settled, 40)
            withExtendedLifetime(renderer) {}
        }
    }

    func testPaintOnlyUpdatePreservesInFlightNativeGeometrySpring() async throws {
        let scene = scene()
        await apply(initialCommands(), to: scene)
        try ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            let animation = ShellAnimation(motion: .spring, speed: 1)
            scene.applyFrame(1, CGRect(x: 40, y: 16, width: 40, height: 64), preset: animation, animated: true)
            scene.flushGlass(animated: true)
            let body = try Self.native(scene.glassBodies[0])
            let key = ShellGlassBody.ElementKey(slot: 1, part: 0)
            let targets = try body.elements.map { try XCTUnwrap($0[key]) } + [try XCTUnwrap(body.maskElements[key])]
            let starts = try targets.map { try XCTUnwrap($0.animation(forKey: ShellGlassBody.Channel.x.key)).beginTime }
            scene.applyGlass(
                0,
                ShellGlassContent(
                    kind: .glass,
                    recipe: recipe,
                    shape: 0,
                    paint: paint(fill: CGColor(gray: 0.5, alpha: 0.36)),
                    params: .zero
                ),
                preset: animation,
                animated: true
            )
            scene.flushGlass(animated: true)
            for (target, start) in zip(targets, starts) {
                let retained = try XCTUnwrap(target.animation(forKey: ShellGlassBody.Channel.x.key))
                XCTAssertEqual(retained.beginTime, start)
            }
        }
    }

    func testNativeRetargetStartsAtPresentedGeometry() async throws {
        let scene = scene()
        await apply(initialCommands(), to: scene)
        try ShellLayerScene.engineQueue.sync {
            let renderer = try ShellOffscreenRenderer(root: scene.container, width: 96, height: 96)
            _ = try renderer.render(paused: CACurrentMediaTime())
            let spring = ShellAnimation(motion: .spring, speed: 1)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scene.applyFrame(1, CGRect(x: 40, y: 16, width: 40, height: 64), preset: spring, animated: true)
            scene.flushGlass(animated: true)
            let body = try Self.native(scene.glassBodies[0])
            let element = try XCTUnwrap(body.elements[1][.init(slot: 1, part: 0)])
            let first = try XCTUnwrap(element.animation(forKey: ShellGlassBody.Channel.x.key))
            CATransaction.commit()
            let midway = first.beginTime + first.duration * 0.2
            let before = try renderer.render(paused: midway)
            let presented = try XCTUnwrap(element.presentation()).position
            XCTAssertGreaterThan(presented.x, 16)
            XCTAssertLessThan(presented.x, 40)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scene.applyFrame(1, CGRect(x: 8, y: 16, width: 48, height: 64), preset: spring, animated: true)
            scene.flushGlass(animated: true)
            let key = ShellGlassBody.Channel.x.key
            let retarget = try XCTUnwrap(element.animation(forKey: key) as? CASpringAnimation)
            XCTAssertEqual(try XCTUnwrap(retarget.fromValue as? NSNumber).doubleValue, presented.x, accuracy: 0.05)
            XCTAssertEqual((retarget.toValue as? NSNumber)?.doubleValue, 8)
            XCTAssertNotEqual(retarget.initialVelocity, 0)
            CATransaction.commit()
            let after = try renderer.render(paused: retarget.beginTime)
            let beforeEdge = try XCTUnwrap((8 ... 55)
                .max { before[(48 * 96 + $0) * 4 + 2] < before[(48 * 96 + $1) * 4 + 2] })
            let afterEdge = try XCTUnwrap((8 ... 55)
                .max { after[(48 * 96 + $0) * 4 + 2] < after[(48 * 96 + $1) * 4 + 2] })
            XCTAssertEqual(afterEdge, beforeEdge)
            try Self.save(after, width: 96, name: "retarget-start.png")
        }
    }

    func testSegmentedEaseUsesMatchingNativeGeometryKeyframes() async throws {
        let scene = scene()
        await apply(initialCommands(), to: scene)
        try ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            let animation = ShellAnimation(
                motion: .ease(seconds: 0.3),
                speed: 1,
                curve: try XCTUnwrap(ShellCurve(wire: 9, custom: nil))
            )
            scene.applyFrame(1, CGRect(x: 40, y: 16, width: 40, height: 64), preset: animation, animated: true)
            scene.flushGlass(animated: true)
            let body = try Self.native(scene.glassBodies[0])
            let key = ShellGlassBody.ElementKey(slot: 1, part: 0)
            let targets = try body.elements.map { try XCTUnwrap($0[key]) } + [try XCTUnwrap(body.maskElements[key])]
            for target in targets {
                let key = ShellGlassBody.Channel.x.key
                let keyframes = try XCTUnwrap(target.animation(forKey: key) as? CAKeyframeAnimation)
                XCTAssertEqual(keyframes.values?.count, 3)
                XCTAssertEqual(keyframes.keyTimes?.first?.doubleValue, 0)
                XCTAssertEqual(keyframes.keyTimes?.last?.doubleValue, 1)
                XCTAssertEqual((keyframes.values?.last as? NSNumber)?.doubleValue, 40)
            }
        }
    }

    func testRetargetAtEightyMillisecondsKeepsTheEdgeAndItsVelocity() async throws {
        let scene = motionScene(width: 240, height: 80)
        let rect = CGRect(x: 20, y: 20, width: 60, height: 40)
        let shape = ShellGlassShape(slot: 1, kind: 0, rect: rect, radius: 8, thickness: 0)
        await apply(motionCommands([shape], size: CGSize(width: 240, height: 80)), to: scene)
        try ShellLayerScene.engineQueue.sync {
            let renderer = try ShellOffscreenRenderer(root: scene.container, width: 240, height: 80)
            func edge(_ time: CFTimeInterval) throws -> Double {
                try XCTUnwrap(Self.crossings(renderer.render(paused: time), width: 240, row: 40).first)
            }
            _ = try renderer.render(paused: CACurrentMediaTime())
            Self.move(scene, [1: rect.offsetBy(dx: 100, dy: 0)], [1: Self.calm])
            let body = try Self.native(scene.glassBodies[0])
            let begin = try XCTUnwrap(Self.assertSprings(body.lockstepLayers(1), .x, like: Self.calm).first)
            let spring = try Self.spring(Self.calm)
            let elapsed = 0.08
            let state = [ShellSpringDynamics.position, ShellSpringDynamics.velocity].map {
                $0(elapsed, -100, 0, spring)
            }
            let (position, velocity) = (120 + state[0], state[1])
            let before = try edge(begin + elapsed)
            Self.move(scene, [1: rect.offsetBy(dx: 20, dy: 0)], [1: Self.calm])
            let layers = body.lockstepLayers(1)
            let begins = try Self.assertSprings(layers, .x, like: Self.calm)
            XCTAssertEqual(begins.count, 1)
            XCTAssertEqual(begins.first ?? 0, begin + elapsed, accuracy: 1e-9)
            let retargets = layers
                .compactMap { $0.animation(forKey: ShellGlassBody.Channel.x.key) as? CASpringAnimation }
            XCTAssertEqual(Set(retargets.map(\.initialVelocity)).count, 1)
            for retarget in retargets {
                let from = try XCTUnwrap(retarget.fromValue as? NSNumber).doubleValue
                XCTAssertEqual(from, position, accuracy: 1e-6)
                XCTAssertEqual(retarget.initialVelocity * (40 - from), velocity, accuracy: 0.5)
            }
            XCTAssertEqual(try edge(begin + elapsed), before, accuracy: 0.5)
            let offset = try edge(begin + 10) - 40
            let step = 1.0 / 60
            let carried = 40 + offset + ShellSpringDynamics.position(
                at: step, displacement: position - 40, initialVelocity: velocity, spring: spring
            )
            let restarted = 40 + offset + ShellSpringDynamics.position(
                at: step, displacement: position - 40, initialVelocity: 0, spring: spring
            )
            let drawn = try edge(begin + elapsed + step)
            XCTAssertEqual(drawn, carried, accuracy: 1)
            XCTAssertGreaterThan(abs(drawn - restarted), 2)
        }
    }

    nonisolated static func shadowed(_ radius: CGFloat) -> ShellLayerPaint {
        ShellLayerPaint(
            fill: CGColor(gray: 1, alpha: 1), border: nil, borderWidth: 0, radius: 0, opacity: 1, scale: 1,
            shadow: CGColor(gray: 0, alpha: 1), shadowRadius: radius, blurRadius: 6, saturation: 1
        )
    }

    nonisolated static func restyle(_ scene: ShellLayerScene, _ recipe: String, shadow: CGFloat, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let content = ShellGlassContent(kind: .glass, recipe: recipe, shape: 0, paint: shadowed(shadow), params: .zero)
        scene.applyGlass(0, content, preset: calm, animated: animated)
        scene.flushGlass(animated: animated)
        CATransaction.commit()
    }

    nonisolated static func bridgeReachAndSkew(_ bytes: [UInt8]) -> [Double] {
        let alpha = { (x: Int, y: Int) in Double(bytes[(y * 240 + x) * 4 + 3]) / 255 }
        let bridge = (0 ..< 130).reduce(0.0) { sum, y in sum + (90 ..< 110).reduce(0.0) { $0 + alpha($1, y) } }
        let reach = (171 ..< 240).count { alpha($0, 60) > 8.0 / 255 }
        let below = (91 ..< 130).count { alpha(140, $0) > 8.0 / 255 }
        let above = (0 ..< 29).count { alpha(140, $0) > 8.0 / 255 }
        return [bridge, Double(reach), Double(below - above)]
    }

    func testBodyBlendAndShadowAnimateOnTheBodySpringAndStepWithoutMotion() async throws {
        let scene = motionScene(width: 240, height: 130)
        let circles = [30.0, 110].enumerated().map { index, x in
            ShellGlassShape(
                slot: Int32(index + 1), kind: 1, rect: CGRect(x: x, y: 30, width: 60, height: 60),
                radius: 0, thickness: 0
            )
        }
        let size = CGSize(width: 240, height: 130)
        await apply(motionCommands(circles, size: size, recipe: "glass:0:-1:0:0:0", body: Self.shadowed(4)), to: scene)
        try ShellLayerScene.engineQueue.sync {
            let renderer = try ShellOffscreenRenderer(root: scene.container, width: 240, height: 130)
            _ = try renderer.render(paused: CACurrentMediaTime())
            Self.restyle(scene, "glass:40:-1:0:0:16", shadow: 24, animated: true)
            let body = try Self.native(scene.glassBodies[0])
            let shadow = [body.sdfLayers[0]]
            var begins = try Self.assertSprings(body.sdfLayers, .smoothness, like: Self.calm)
            try begins.formUnion(Self.assertSprings(shadow, .shadowRadius, like: Self.calm))
            try begins.formUnion(Self.assertSprings(shadow, .shadowOffset, like: Self.calm))
            XCTAssertEqual(begins.count, 1)
            let begin = try XCTUnwrap(begins.first)
            let samples = try [0, 0.12, 10].map { try Self.bridgeReachAndSkew(renderer.render(paused: begin + $0)) }
            for index in 0 ..< 3 {
                let values = samples.map { $0[index] }
                XCTAssertGreaterThan(values[2] - values[0], 4, "measure \(index): \(samples)")
                XCTAssertGreaterThan(values[1], values[0] + 1, "measure \(index): \(samples)")
                XCTAssertLessThan(values[1], values[2] - 1, "measure \(index): \(samples)")
            }
            Self.restyle(scene, "glass:8:-1:0:0:2", shadow: 6, animated: false)
            for channel in [ShellGlassBody.Channel.smoothness, .shadowRadius, .shadowOffset] {
                XCTAssertTrue(body.sdfLayers.allSatisfy { $0.animation(forKey: channel.key) == nil })
            }
        }
    }
}
