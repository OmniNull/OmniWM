// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
extension ShellGlassSceneTests {
    nonisolated static let calm = ShellAnimation(motion: .spring(response: 0.513, bounce: 0.06), speed: 1)
    nonisolated static let dock = ShellAnimation(motion: .spring(response: 0.322, bounce: 0.23), speed: 1)
    nonisolated static let thin = "glass:4:-1:0:0:1"

    func motionScene(width: CGFloat, height: CGFloat, native: Bool = true) -> ShellLayerScene {
        let layer = CALayer()
        layer.isGeometryFlipped = true
        layer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        return ShellLayerScene(container: layer, scale: 1, glassNativeEnabled: native)
    }

    func motionCommands(
        _ shapes: [ShellGlassShape],
        size: CGSize,
        recipe: String = ShellGlassSceneTests.thin,
        body: ShellLayerPaint? = nil
    ) -> [ShellLayerCommand] {
        var commands: [ShellLayerCommand] = [
            .insert(slot: 0, parent: -1, kind: .glass, after: -1),
            bodyGlass(
                recipe: recipe,
                paint: body ?? paint(fill: CGColor(gray: 1, alpha: 1), shadow: ShellLayerScene.clear)
            ),
            .frame(slot: 0, rect: CGRect(origin: .zero, size: size), animation: nil)
        ]
        var after: Int32 = -1
        for shape in shapes {
            var look = paint(radius: shape.radius)
            look.rotation = shape.rotation
            commands += [
                .insert(slot: shape.slot, parent: 0, kind: .shape, after: after),
                .glass(
                    slot: shape.slot,
                    ShellGlassContent(
                        kind: .shape, recipe: "", shape: shape.kind, paint: look,
                        params: SIMD4(Float(shape.thickness), 0, 0, 0)
                    ),
                    animation: nil
                ),
                .frame(slot: shape.slot, rect: shape.rect, animation: nil)
            ]
            after = shape.slot
        }
        return commands
    }

    nonisolated static func crossings(_ bytes: [UInt8], width: Int, row: Int) -> [Double] {
        let alpha = { (x: Int) in Double(bytes[(row * width + x) * 4 + 3]) / 255 }
        return (0 ..< width - 1).compactMap { x in
            let inside = alpha(x)
            let next = alpha(x + 1)
            guard (inside >= 0.5) != (next >= 0.5) else { return nil }
            return Double(x) + 0.5 + (inside - 0.5) / (inside - next)
        }
    }

    nonisolated static func mask(_ bytes: [UInt8]) -> [Bool] {
        stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] >= 128 }
    }

    nonisolated static func spring(_ animation: ShellAnimation) throws -> ShellSpringDynamics.Parameters {
        try XCTUnwrap(ShellSpringDynamics.Parameters(animation))
    }

    nonisolated static func move(
        _ scene: ShellLayerScene,
        _ frames: [Int32: CGRect],
        _ motions: [Int32: ShellAnimation]
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (slot, rect) in frames { scene.applyFrame(slot, rect, preset: motions[slot], animated: true) }
        scene.flushGlass(animated: true)
        CATransaction.commit()
    }

    nonisolated static func assertSprings(
        _ layers: [CALayer],
        _ channel: ShellGlassBody.Channel,
        like animation: ShellAnimation
    ) throws -> Set<CFTimeInterval> {
        let expected = try XCTUnwrap(animation.make(channel.keyPath) as? CASpringAnimation)
        var begins: Set<CFTimeInterval> = []
        for layer in layers {
            let spring = try XCTUnwrap(layer.animation(forKey: channel.key) as? CASpringAnimation, channel.key)
            XCTAssertEqual(spring.keyPath, channel.keyPath)
            XCTAssertEqual(spring.stiffness, expected.stiffness, accuracy: 1e-9)
            XCTAssertEqual(spring.damping, expected.damping, accuracy: 1e-9)
            XCTAssertEqual(spring.mass, expected.mass, accuracy: 1e-9)
            begins.insert(spring.beginTime)
        }
        return begins
    }

    nonisolated static func reference(_ kind: UInt8, _ rect: CGRect, rotation: CGFloat, size: CGSize) throws -> [Bool] {
        let root = CALayer()
        let reference = CAShapeLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.isGeometryFlipped = true
        root.frame = CGRect(origin: .zero, size: size)
        reference.bounds = CGRect(origin: .zero, size: rect.size)
        reference.position = CGPoint(x: rect.midX, y: rect.midY)
        reference.path = kind == 1 ? CGPath(ellipseIn: reference.bounds, transform: nil)
            : CGPath(rect: reference.bounds, transform: nil)
        reference.fillColor = CGColor(gray: 1, alpha: 1)
        reference.transform = CATransform3DMakeRotation(rotation, 0, 0, 1)
        root.addSublayer(reference)
        CATransaction.commit()
        return try mask(ShellOffscreenRenderer(root: root, width: Int(size.width), height: Int(size.height)).render())
    }

    nonisolated static func strays(_ drawn: [Bool], from expected: [Bool], width: Int) -> Int {
        var count = 0
        for y in 1 ..< expected.count / width - 1 {
            for x in 1 ..< width - 1 where drawn[y * width + x] != expected[y * width + x] {
                let band = (-1 ... 1).flatMap { dy in (-1 ... 1).map { expected[(y + dy) * width + x + $0] } }
                if Set(band).count == 1 { count += 1 }
            }
        }
        return count
    }

    func testShapesInOneBodyFollowTheirOwnSpringsAndMatchTheAnalyticEdges() async throws {
        let scene = motionScene(width: 240, height: 160)
        let shapes = [20.0, 100].enumerated().map { index, y in
            ShellGlassShape(
                slot: Int32(index + 1), kind: 0, rect: CGRect(x: 20, y: y, width: 60, height: 40),
                radius: 8, thickness: 0
            )
        }
        await apply(motionCommands(shapes, size: CGSize(width: 240, height: 160)), to: scene)
        try ShellLayerScene.engineQueue.sync {
            let renderer = try ShellOffscreenRenderer(root: scene.container, width: 240, height: 160)
            _ = try renderer.render(paused: CACurrentMediaTime())
            let motions = [Self.calm, Self.dock]
            Self.move(
                scene,
                [1: shapes[0].rect.offsetBy(dx: 100, dy: 0), 2: shapes[1].rect.offsetBy(dx: 100, dy: 0)],
                [1: motions[0], 2: motions[1]]
            )
            let body = try Self.native(scene.glassBodies[0])
            var begins: Set<CFTimeInterval> = []
            for (shape, motion) in zip(shapes, motions) {
                XCTAssertEqual(body.lockstepLayers(shape.slot).count, 5)
                try begins.formUnion(Self.assertSprings(body.lockstepLayers(shape.slot), .x, like: motion))
            }
            XCTAssertEqual(begins.count, 1)
            let begin = try XCTUnwrap(begins.first)
            let rows = [40, 120]
            let settled = try renderer.render(paused: begin + 10)
            let offsets = rows.map { (Self.crossings(settled, width: 240, row: $0).first ?? .nan) - 120 }
            XCTAssertTrue(offsets.allSatisfy { abs($0) <= 1.5 }, "\(offsets)")
            for elapsed in [0.03, 0.08, 0.16, 0.3] {
                let bytes = try renderer.render(paused: begin + elapsed)
                let drawn = try rows.map { try XCTUnwrap(Self.crossings(bytes, width: 240, row: $0).first) }
                for (index, motion) in motions.enumerated() {
                    let analytic = try 120 + ShellSpringDynamics.position(
                        at: elapsed, displacement: -100, initialVelocity: 0, spring: Self.spring(motion)
                    )
                    XCTAssertEqual(drawn[index], analytic + offsets[index], accuracy: 1, "t=\(elapsed) shape \(index)")
                }
                if elapsed == 0.08 { XCTAssertGreaterThan(abs(drawn[1] - drawn[0]), 10) }
            }
        }
    }

    func testFrameHoleRetargetKeepsMaskStripsOnTheHoleEdges() async throws {
        let frame = CGRect(x: -40, y: -40, width: 176, height: 176)
        let scenes = [motionScene(width: 96, height: 96), motionScene(width: 96, height: 96, native: false)]
        for scene in scenes {
            let shape = ShellGlassShape(slot: 1, kind: 2, rect: frame, radius: 0, thickness: 56)
            await apply(
                motionCommands([shape], size: CGSize(width: 96, height: 96), recipe: "glass:8:-1:0:0:1"),
                to: scene
            )
        }
        try ShellLayerScene.engineQueue.sync {
            let native = try Self.native(scenes[0].glassBodies[0])
            let renderers = try scenes.map { try ShellOffscreenRenderer(root: $0.container, width: 96, height: 96) }
            func pause(_ time: CFTimeInterval) throws -> [[Double]] {
                try renderers.map { try Self.crossings($0.render(paused: time), width: 96, row: 48) }
            }
            func reshape(dx: CGFloat, dw: CGFloat) {
                let rect = CGRect(x: frame.minX + dx, y: frame.minY, width: frame.width + dw, height: frame.height)
                for scene in scenes { Self.move(scene, [1: rect], [1: Self.calm]) }
            }
            var samples = try [pause(CACurrentMediaTime())]
            reshape(dx: 10, dw: -10)
            let hole = try XCTUnwrap(native.elements[1][.init(slot: 1, part: 1)])
            let strip = try XCTUnwrap(native.maskElements[.init(slot: 1, part: 3)])
            let container = try XCTUnwrap(native.maskContainers[1])
            var begins = try Self.assertSprings([hole, container, strip], .x, like: Self.calm)
            try begins.formUnion(Self.assertSprings([hole, container], .width, like: Self.calm))
            XCTAssertEqual(begins.count, 1)
            let begin = try XCTUnwrap(begins.first)
            try samples += [pause(begin + 0.04), pause(begin + 0.08)]
            reshape(dx: -10, dw: 20)
            for elapsed in [0.08, 0.11, 0.2, 10] { try samples.append(pause(begin + elapsed)) }
            for (index, sample) in samples.enumerated() {
                XCTAssertEqual(sample.map(\.count), [2, 2], "sample \(index)")
                for (hole, strip) in zip(sample[0], sample[1]) {
                    XCTAssertEqual(strip, hole, accuracy: 1, "sample \(index): \(sample)")
                }
            }
            for (edge, expected) in zip(samples[0][0] + samples[6][0], [16.0, 80, 6, 90]) {
                XCTAssertEqual(edge, expected, accuracy: 0.5)
            }
            XCTAssertEqual(samples[3][0][0], samples[2][0][0], accuracy: 0.5)
            XCTAssertTrue((16.5 ... 25.5).contains(samples[2][0][0]), "\(samples[2])")
        }
    }

    func testRotateTurnsRectAndEllipseAboutTheirCentresComposedWithTheEllipseScale() async throws {
        let rect = CGRect(x: 50, y: 45, width: 60, height: 30)
        let size = CGSize(width: 160, height: 120)
        for kind: UInt8 in [0, 1] {
            let scene = motionScene(width: size.width, height: size.height)
            let shape = ShellGlassShape(slot: 1, kind: kind, rect: rect, radius: 0, thickness: 0, rotation: .pi / 6)
            await apply(motionCommands([shape], size: size), to: scene)
            try ShellLayerScene.engineQueue.sync {
                _ = try Self.native(scene.glassBodies[0])
                let drawn = try Self
                    .mask(ShellOffscreenRenderer(root: scene.container, width: 160, height: 120).render())
                let turned = try Self.reference(kind, rect, rotation: .pi / 6, size: size)
                let still = try Self.reference(kind, rect, rotation: 0, size: size)
                XCTAssertEqual(Self.strays(drawn, from: turned, width: 160), 0, "shape kind \(kind)")
                XCTAssertGreaterThan(Self.strays(drawn, from: still, width: 160), 100, "shape kind \(kind)")
            }
        }
    }

    private func springWidget(reducesMotion: Bool) throws
        -> (widget: ShellRenderedWidget, renderer: ShellOffscreenRenderer)
    {
        let policy = MotionPolicy()
        policy.systemReducesMotion = reducesMotion
        let widget = try ShellRenderedWidget(name: "glass-springs", source: """
        function render(ctx) return ui.box{w=1,h=1} end
        function popout(ctx)
            local step = ctx.data.seconds
            return ui.stack{w=240,h=160,ui.glass{key='body',w=240,h=160,animate='spring',
                ui.shape{key='plain',w=40+step*20,h=40,radius=8},
                ui.shape{key='own',w=40+step*20,h=40,radius=8,dy=80,animate={response=0.322,bounce=0.23}}}}
        end
        """, resources: ShellResources(motion: policy))
        widget.set("seconds") { $0.number(1) }
        widget.layoutPopout()
        let renderer = try ShellLayerScene.engineQueue.sync {
            let container = widget.surface.scene.container
            container.frame = CGRect(x: 0, y: 0, width: 240, height: 160)
            let renderer = try ShellOffscreenRenderer(root: container, width: 240, height: 160)
            _ = try renderer.render(paused: CACurrentMediaTime())
            return renderer
        }
        widget.set("seconds") { $0.number(2) }
        widget.layoutPopout()
        return (widget, renderer)
    }

    func testShapesWithoutOwnAnimateKeepTheBodySpringAndReduceMotionAddsNone() throws {
        for reducesMotion in [false, true] {
            let (widget, renderer) = try springWidget(reducesMotion: reducesMotion)
            let surface = widget.surface
            let shapes = surface.layout.core.elements { _ in true }
                .filter { surface.layout.core.kind(of: $0) == .shape }
            let own = ShellAnimation(motion: .spring(response: 0.322, bounce: 0.23), speed: 1)
            let inherited = ShellAnimation(motion: .spring, speed: 1)
            let motions = shapes.map { surface.layout.core.content(of: $0).motion != 0 ? own : inherited }
            XCTAssertEqual(motions.map(\.motion).filter { $0 == own.motion }.count, 1)
            var commanded: [Int32: ShellMotion] = [:]
            for case let .frame(slot, _, animation?) in surface.commands(text: widget.text) {
                commanded[slot] = animation.motion
            }
            XCTAssertEqual(shapes.compactMap { commanded[$0.slot] }, motions.map(\.motion))
            try ShellLayerScene.engineQueue.sync {
                let body = try Self.native(surface.scene.glassBodies.values.first)
                for (shape, motion) in zip(shapes, motions) {
                    let layers = body.lockstepLayers(shape.slot)
                    if reducesMotion {
                        XCTAssertTrue(layers.allSatisfy { $0.animationKeys()?.isEmpty ?? true })
                    } else {
                        XCTAssertEqual(try Self.assertSprings(layers, .width, like: motion).count, 1)
                    }
                }
                if reducesMotion {
                    XCTAssertTrue(body.canvasLayers.allSatisfy { $0.animationKeys()?.isEmpty ?? true })
                }
            }
            withExtendedLifetime(renderer) {}
        }
    }

    func testShapeSpringsGiveWayToRevealOwnedKeys() throws {
        let body = ShellGlassBody()
        guard body.nativeAvailable else { throw XCTSkip(body.failure ?? "Native glass is unavailable") }
        let recipe = try XCTUnwrap(ShellGlassRecipe(Self.thin))
        let look = paint()
        func place(_ rect: CGRect, _ animation: ShellAnimation?) {
            body.apply(
                size: CGSize(width: 240, height: 80),
                shapes: [ShellGlassShape(slot: 1, kind: 0, rect: rect, radius: 8, thickness: 0)],
                recipe: recipe, paint: look, animation: nil,
                shapeAnimations: animation.map { [1: $0] } ?? [:]
            )
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        place(CGRect(x: 20, y: 20, width: 60, height: 40), nil)
        place(CGRect(x: 60, y: 20, width: 60, height: 40), Self.calm)
        let layers = body.lockstepLayers(1)
        XCTAssertEqual(try Self.assertSprings(layers, .x, like: Self.calm).count, 1)
        let reveal = CAKeyframeAnimation(keyPath: "position")
        reveal.values = [NSValue(point: .zero), NSValue(point: CGPoint(x: 60, y: 20))]
        reveal.duration = 1
        for layer in layers { layer.add(reveal, forKey: "omni.glass.position") }
        place(CGRect(x: 100, y: 30, width: 80, height: 40), Self.calm)
        for layer in layers {
            XCTAssertNil(layer.animation(forKey: ShellGlassBody.Channel.x.key))
            XCTAssertNil(layer.animation(forKey: ShellGlassBody.Channel.y.key))
            XCTAssertNotNil(layer.animation(forKey: "omni.glass.position"))
        }
        XCTAssertEqual(try Self.assertSprings(layers, .width, like: Self.calm).count, 1)
    }
}
