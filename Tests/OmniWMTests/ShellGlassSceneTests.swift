// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellGlassSceneTests: XCTestCase {
    let recipe = "glass:26:-1:0:0:1"

    func paint(fill: CGColor? = nil, shadow: CGColor? = nil, radius: CGFloat = 0) -> ShellLayerPaint {
        ShellLayerPaint(
            fill: fill,
            border: nil,
            borderWidth: 0,
            radius: radius,
            opacity: 1,
            scale: 1,
            shadow: shadow,
            shadowRadius: 6,
            blurRadius: 6,
            saturation: 1
        )
    }

    nonisolated static func native(_ body: ShellGlassBody?) throws -> ShellGlassBody {
        let body = try XCTUnwrap(body)
        guard body.nativeAvailable else { throw XCTSkip(body.failure ?? "Native glass is unavailable") }
        return body
    }

    func scene(native: Bool = true) -> ShellLayerScene {
        let layer = CALayer()
        layer.isGeometryFlipped = true
        layer.frame = CGRect(x: 0, y: 0, width: 96, height: 96)
        return ShellLayerScene(container: layer, scale: 2, glassNativeEnabled: native)
    }

    func apply(_ commands: [ShellLayerCommand], to scene: ShellLayerScene, animated: Bool = false) async {
        await withCheckedContinuation { continuation in
            scene.submit(commands, animated: animated) {
                continuation.resume()
            }
        }
    }

    func bodyGlass(
        recipe: String? = nil,
        paint: ShellLayerPaint? = nil,
        animation: ShellAnimation? = nil
    ) -> ShellLayerCommand {
        .glass(
            slot: 0,
            ShellGlassContent(
                kind: .glass,
                recipe: recipe ?? self.recipe,
                shape: 0,
                paint: paint ?? self.paint(),
                params: .zero
            ),
            animation: animation
        )
    }

    func shapeGlass(_ slot: Int32 = 1, shape: UInt8, radius: CGFloat = 0, thickness: Float = 0) -> ShellLayerCommand {
        .glass(
            slot: slot,
            ShellGlassContent(
                kind: .shape,
                recipe: "",
                shape: shape,
                paint: paint(radius: radius),
                params: SIMD4(thickness, 0, 0, 0)
            ),
            animation: nil
        )
    }

    func initialCommands(
        shape: UInt8 = 0,
        rect: CGRect = CGRect(x: 16, y: 16, width: 64, height: 64),
        thickness: Float = 0,
        radius: CGFloat = 0
    ) -> [ShellLayerCommand] {
        [
            .insert(slot: 0, parent: -1, kind: .glass, after: -1),
            bodyGlass(),
            .frame(slot: 0, rect: CGRect(x: 0, y: 0, width: 96, height: 96), animation: nil),
            .insert(slot: 1, parent: 0, kind: .shape, after: -1),
            shapeGlass(shape: shape, radius: radius, thickness: thickness),
            .frame(slot: 1, rect: rect, animation: nil)
        ]
    }

    func testWireToSurfaceBuildsOneDecorativeNativeBody() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.stack{w=160,h=100,ui.glass{key='body',
                ui.shape{key='card',w=80,h=60,dx=10,dy=20,radius=12},
                ui.shape{key='ellipse',shape='ellipse',w=30,h=20,dx=70,dy=40}}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let text = ShellTextStore()
        text.ingest(wire: script.output)
        let surface = ShellWidgetSurface(
            scale: 2,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            directories: []
        )
        XCTAssertTrue(surface.apply(script.output, text: text))
        try ShellLayerScene.engineQueue.sync {
            XCTAssertEqual(surface.scene.glassBodies.count, 1)
            let body = try Self.native(surface.scene.glassBodies.values.first)
            XCTAssertEqual(body.elements[1].count, 2)
            XCTAssertEqual(body.maskElements.count, 2)
        }
    }

    func testKeyedShapeMoveReorderAndRemovalRetainMatchingNativeElements() async throws {
        let scene = scene()
        await apply(initialCommands() + [
            .insert(slot: 2, parent: 0, kind: .shape, after: 1),
            shapeGlass(2, shape: 1),
            .frame(slot: 2, rect: CGRect(x: 60, y: 30, width: 30, height: 20), animation: nil)
        ], to: scene)
        let key = ShellGlassBody.ElementKey(slot: 1, part: 0)
        let first = try ShellLayerScene.engineQueue
            .sync { try XCTUnwrap(Self.native(scene.glassBodies[0]).elements[1][key]) }
        await apply([
            .frame(slot: 1, rect: CGRect(x: 20, y: 22, width: 60, height: 50), animation: nil),
            .move(slot: 1, after: 2)
        ], to: scene)
        ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(scene.glassBodies[0]?.elements[1][key] === first)
            XCTAssertEqual(first.position, CGPoint(x: 20, y: 22))
            XCTAssertTrue(scene.glassBodies[0]?.sdfLayers[1].sublayers?.last === first)
            XCTAssertTrue(scene.layers[1]?.isHidden == true)
        }
        await apply([.remove(slot: 1)], to: scene)
        ShellLayerScene.engineQueue.sync {
            XCTAssertNil(scene.glassBodies[0]?.elements[1][key])
            XCTAssertEqual(scene.glassBodies[0]?.elements[1].count, 1)
            XCTAssertEqual(scene.glassBodies[0]?.maskElements.count, 1)
        }
        await apply([.remove(slot: 0)], to: scene)
        ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(scene.glassBodies.isEmpty)
            XCTAssertTrue(scene.glassShapes.isEmpty)
            XCTAssertTrue(scene.glassShapeSlots.isEmpty)
            XCTAssertTrue(scene.layers.isEmpty)
        }
    }

    func testShapeFramesAnimateGlassGeometryWithoutPresenceAnimations() async throws {
        let scene = scene()
        await apply(initialCommands() + [
            .insert(slot: 2, parent: 0, kind: .shape, after: 1),
            shapeGlass(2, shape: 1)
        ], to: scene)
        try ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            let spring = ShellAnimation(motion: .spring, speed: 1)
            scene.applyFrame(2, CGRect(x: 60, y: 30, width: 30, height: 20), preset: spring, animated: true)
            scene.applyFrame(1, CGRect(x: 40, y: 16, width: 40, height: 64), preset: spring, animated: true)
            scene.flushGlass(animated: true)
            let mask = try XCTUnwrap(scene.glassBodies[0]?.maskElements[.init(slot: 1, part: 0)])
            XCTAssertNotNil(mask.animation(forKey: ShellGlassBody.Channel.x.key))
            for slot: Int32 in [1, 2] {
                XCTAssertNil(scene.exitAnimations[slot])
                XCTAssertNil(scene.layers[slot]?.animation(forKey: ShellLayerScene.appearanceKey))
            }
            let inserted = try XCTUnwrap(scene.layers[2])
            scene.retirePresence(2, subtree: inserted, animated: true)
            XCTAssertNil(inserted.superlayer)
            XCTAssertTrue(scene.presence.retained.isEmpty)
        }
    }

    func testBaseMaskExcludesUnionFilletAndEllipseUsesMatchingTransform() async throws {
        let scene = scene()
        await apply(initialCommands(rect: CGRect(x: 20, y: 20, width: 40, height: 40)) + [
            .insert(slot: 2, parent: 0, kind: .shape, after: 1),
            shapeGlass(2, shape: 0),
            .frame(slot: 2, rect: CGRect(x: 60, y: 60, width: 30, height: 30), animation: nil)
        ], to: scene)
        try ShellLayerScene.engineQueue.sync {
            let body = try Self.native(scene.glassBodies[0])
            let fillet = CGPoint(x: 65, y: 55)
            for mask in body.maskElements.values { XCTAssertFalse(mask.frame.contains(fillet)) }
            XCTAssertEqual(body.sdfLayers[1].value(forKey: "smoothness") as? CGFloat, 52)
        }
        await apply([
            shapeGlass(2, shape: 1),
            .frame(slot: 2, rect: CGRect(x: 55, y: 60, width: 30, height: 16), animation: nil)
        ], to: scene)
        try ShellLayerScene.engineQueue.sync {
            let body = try Self.native(scene.glassBodies[0])
            let key = ShellGlassBody.ElementKey(slot: 2, part: 0)
            let element = try XCTUnwrap(body.elements[1][key])
            let mask = try XCTUnwrap(body.maskElements[key])
            XCTAssertEqual(element.bounds, mask.bounds)
            XCTAssertEqual(element.cornerRadius, mask.cornerRadius)
            XCTAssertTrue(CATransform3DEqualToTransform(element.transform, mask.transform))
            XCTAssertEqual(element.transform.m11, 30.0 / 16.0)
        }
    }

    func testFrameMaskAndNativeBoundsFollowCanvasAndFrameResize() async throws {
        let scene = scene()
        await apply(
            initialCommands(shape: 2, rect: CGRect(x: -64, y: -64, width: 224, height: 224), thickness: 72),
            to: scene
        )
        try ShellLayerScene.engineQueue.sync {
            let body = try Self.native(scene.glassBodies[0])
            XCTAssertTrue(body.nativeAvailable)
            XCTAssertEqual(body.maskElements.count, 8)
            XCTAssertEqual(body.elements[1].count, 2)
        }
        await apply([
            .frame(slot: 0, rect: CGRect(x: 0, y: 0, width: 120, height: 80), animation: nil),
            .frame(slot: 1, rect: CGRect(x: -64, y: -64, width: 248, height: 208), animation: nil)
        ], to: scene)
        try ShellLayerScene.engineQueue.sync {
            let body = try Self.native(scene.glassBodies[0])
            XCTAssertTrue(body.nativeAvailable)
            XCTAssertEqual(body.layer.bounds.size, CGSize(width: 120, height: 80))
            XCTAssertEqual(body.maskElements[.init(slot: 1, part: 1)]?.position.y, 136)
            XCTAssertEqual(body.maskElements[.init(slot: 1, part: 3)]?.position.x, 176)
        }
    }

    func testUnavailableNativeCapabilityUsesMaskedMaterialAndTint() async throws {
        let scene = scene(native: false)
        await apply(initialCommands(), to: scene)
        try ShellLayerScene.engineQueue.sync {
            let body = try XCTUnwrap(scene.glassBodies[0])
            XCTAssertFalse(body.nativeAvailable)
            XCTAssertTrue(body.sdfLayers.isEmpty)
            XCTAssertEqual(body.maskElements.count, 1)
            XCTAssertEqual(body.layer.sublayers?.count, 2)
            let tint = try XCTUnwrap(body.layer.sublayers?.last)
            let mask = try XCTUnwrap(tint.mask)
            XCTAssertEqual(mask.sublayers?.count, 1)
            XCTAssertEqual(mask.sublayers?.first?.frame, CGRect(x: 16, y: 16, width: 64, height: 64))
            XCTAssertEqual(tint.backgroundColor?.alpha ?? 0, 0.36, accuracy: 0.001)
        }
    }

    func testExplicitTransparentWirePaintDisablesNativeTintAndShadow() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.glass{w=96,h=96,fill='#00000000',shadow='#00000000',ui.shape{w=80,h=80}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let text = ShellTextStore()
        text.ingest(wire: script.output)
        let surface = ShellWidgetSurface(
            scale: 2,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            directories: []
        )
        XCTAssertTrue(surface.apply(script.output, text: text))
        try ShellLayerScene.engineQueue.sync {
            let body = try Self.native(surface.scene.glassBodies.values.first)
            for layer in [body.sdfLayers[0], body.sdfLayers[1]] {
                let effect = try XCTUnwrap(layer.value(forKey: "effect") as? NSObject)
                let color = try XCTUnwrap(effect.value(forKey: "color")) as AnyObject
                XCTAssertTrue(CFEqual(color, ShellLayerScene.clear))
            }
        }
    }

    func testGlassPaintDoesNotAddHostTintOrAnimatedHostShadow() async throws {
        let scene = scene()
        await apply(initialCommands(), to: scene)
        let next = paint(
            fill: CGColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 0.36),
            shadow: CGColor(gray: 0, alpha: 0.2)
        )
        await apply(
            [bodyGlass(paint: next, animation: ShellAnimation(motion: .spring, speed: 1))],
            to: scene,
            animated: true
        )
        try ShellLayerScene.engineQueue.sync {
            let host = try XCTUnwrap(scene.layers[0])
            XCTAssertEqual(host.backgroundColor?.alpha ?? 0, 0)
            XCTAssertEqual(host.shadowOpacity, 0)
            XCTAssertNil(host.animation(forKey: "shadowOpacity"))
            let body = try Self.native(scene.glassBodies[0])
            let effect = try XCTUnwrap(body.sdfLayers[1].value(forKey: "effect") as? NSObject)
            let actual = try XCTUnwrap(effect.value(forKey: "color")) as AnyObject
            XCTAssertEqual(CFGetTypeID(actual), CGColor.typeID)
            XCTAssertTrue(CFEqual(actual, try XCTUnwrap(next.fill)))
        }
    }
}
