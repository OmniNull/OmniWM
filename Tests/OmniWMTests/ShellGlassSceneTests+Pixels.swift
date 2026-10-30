// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ImageIO
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import UniformTypeIdentifiers
import XCTest

@MainActor
extension ShellGlassSceneTests {
    func testFallbackPixelsFollowBaseShapeCoverage() async throws {
        let scene = scene(native: false)
        await apply(initialCommands(), to: scene)
        try ShellLayerScene.engineQueue.sync {
            let body = try XCTUnwrap(scene.glassBodies[0])
            let pixels = try Self.pixels(body.layer, width: 96, height: 96, scale: 1)
            XCTAssertGreaterThan(pixels[(48 * 96 + 48) * 4 + 3], 80)
            XCTAssertEqual(pixels[(8 * 96 + 8) * 4 + 3], 0)
            try Self.save(pixels, width: 96, name: "fallback-body.png")
        }
    }

    func testOffscreenNativeBodyHasTintDirectionalRimAndClearExterior() async throws {
        let scene = scene()
        await apply(initialCommands(radius: 12), to: scene)
        try ShellLayerScene.engineQueue.sync {
            let body = try Self.native(scene.glassBodies[0])
            XCTAssertTrue(body.nativeAvailable)
            for scale in [1, 2] {
                let width = 96 * scale
                let pixels = try Self.pixels(body.layer, width: width, height: width, scale: scale)
                let center = (48 * scale * width + 48 * scale) * 4
                XCTAssertGreaterThan(pixels[center], pixels[center + 2])
                var leftRim: UInt8 = 0
                for x in (14 * scale) ... (20 * scale) {
                    let index = (48 * scale * width + x) * 4 + 2
                    leftRim = max(leftRim, pixels[index])
                }
                XCTAssertGreaterThan(Int(leftRim), Int(pixels[center + 2]) + 40)
                XCTAssertEqual(pixels[(2 * scale * width + 2 * scale) * 4 + 3], 0)
                let rightRim = (76 * scale ... 82 * scale).map { pixels[(48 * scale * width + $0) * 4 + 2] }.max() ?? 0
                XCTAssertGreaterThan(Int(leftRim), Int(rightRim) + 20)
                let nearShadow = pixels[(48 * scale * width + 82 * scale) * 4 + 3]
                let farShadow = pixels[(48 * scale * width + 86 * scale) * 4 + 3]
                XCTAssertGreaterThan(nearShadow, farShadow)
                XCTAssertGreaterThan(farShadow, 0)
                body.sdfLayers[0].isHidden = true
                let withoutShadow = try Self.pixels(body.layer, width: width, height: width, scale: scale)
                XCTAssertGreaterThan(nearShadow, withoutShadow[(48 * scale * width + 82 * scale) * 4 + 3])
                XCTAssertEqual(Array(pixels[center ..< center + 4]), Array(withoutShadow[center ..< center + 4]))
                body.sdfLayers[0].isHidden = false
                body.sdfLayers[3].isHidden = true
                let withoutGlow = try Self.pixels(body.layer, width: width, height: width, scale: scale)
                let glow = (48 * scale * width + 24 * scale) * 4 + 2
                XCTAssertGreaterThan(pixels[glow], withoutGlow[glow])
                body.sdfLayers[3].isHidden = false
                try Self.save(pixels, width: width, name: "native-body-\(scale)x.png")
            }
        }
    }

    func testRoundedInsetFrameKeepsHoleAndExteriorClear() async throws {
        let scene = scene()
        await apply(
            initialCommands(shape: 2, rect: CGRect(x: 8, y: 8, width: 80, height: 80), thickness: 8, radius: 24),
            to: scene
        )
        try ShellLayerScene.engineQueue.sync {
            let body = try XCTUnwrap(scene.glassBodies[0])
            XCTAssertFalse(body.nativeAvailable)
            let corner = try XCTUnwrap(body.maskElements[.init(slot: 1, part: 4)])
            XCTAssertGreaterThan(abs(corner.transform.m11), 0)
            let pixels = try Self.pixels(body.layer, width: 96, height: 96, scale: 1)
            XCTAssertEqual(pixels[(48 * 96 + 48) * 4 + 3], 0)
            XCTAssertEqual(pixels[(2 * 96 + 2) * 4 + 3], 0)
            XCTAssertGreaterThan(pixels[(48 * 96 + 11) * 4 + 3], 0)
            try Self.save(pixels, width: 96, name: "rounded-frame.png")
        }
        await apply([.frame(slot: 1, rect: CGRect(x: -1, y: -1, width: 98, height: 98), animation: nil)], to: scene)
        try ShellLayerScene.engineQueue.sync {
            let body = try XCTUnwrap(scene.glassBodies[0])
            XCTAssertFalse(body.nativeAvailable)
            let pixels = try Self.pixels(body.layer, width: 96, height: 96, scale: 1)
            XCTAssertEqual(pixels[(48 * 96 + 48) * 4 + 3], 0)
            XCTAssertGreaterThan(pixels[(48 * 96 + 2) * 4 + 3], 0)
        }
        await apply([shapeGlass(shape: 2, thickness: 50)], to: scene)
        try ShellLayerScene.engineQueue.sync {
            let body = try XCTUnwrap(scene.glassBodies[0])
            XCTAssertFalse(body.nativeAvailable)
            XCTAssertTrue(body.maskElements.isEmpty)
            let pixels = try Self.pixels(body.layer, width: 96, height: 96, scale: 1)
            XCTAssertTrue(pixels.allSatisfy { $0 == 0 })
        }
        await apply([shapeGlass(shape: 2, thickness: 8)], to: scene)
        try ShellLayerScene.engineQueue.sync {
            let body = try XCTUnwrap(scene.glassBodies[0])
            XCTAssertFalse(body.nativeAvailable)
            XCTAssertTrue(body.elements[1].isEmpty)
            XCTAssertEqual(body.maskElements.count, 8)
        }
    }

    func testOversizedRoundedFrameUsesNativeEffectsAndRecoversAfterInvalidGeometry() async throws {
        let scene = scene()
        let rect = CGRect(x: -64, y: -64, width: 224, height: 224)
        await apply(initialCommands(shape: 2, rect: rect, thickness: 72, radius: 88), to: scene)
        try ShellLayerScene.engineQueue.sync {
            let body = try Self.native(scene.glassBodies[0])
            for scale in [1, 2] {
                let width = 96 * scale
                let pixels = try Self.pixels(body.layer, width: width, height: width, scale: scale)
                XCTAssertEqual(pixels[(48 * scale * width + 48 * scale) * 4 + 3], 0)
                XCTAssertGreaterThan(pixels[(48 * scale * width + 4 * scale) * 4 + 3], 0)
                try Self.save(pixels, width: width, name: "oversized-rounded-frame-\(scale)x.png")
            }
        }
        await apply([shapeGlass(shape: 2, radius: 88, thickness: 120)], to: scene)
        ShellLayerScene.engineQueue.sync {
            XCTAssertFalse(scene.glassBodies[0]?.nativeAvailable == true)
            XCTAssertTrue(scene.glassBodies[0]?.maskElements.isEmpty == true)
        }
        await apply([shapeGlass(shape: 2, radius: 88, thickness: 72)], to: scene)
        try ShellLayerScene.engineQueue.sync {
            let body = try Self.native(scene.glassBodies[0])
            XCTAssertEqual(body.elements[1].count, 2)
            XCTAssertEqual(body.maskElements.count, 8)
        }
        await apply([bodyGlass(recipe: "glass:4:-1:0:0:1")], to: scene)
        try ShellLayerScene.engineQueue.sync {
            let body = try XCTUnwrap(scene.glassBodies[0])
            XCTAssertFalse(body.nativeAvailable)
            let pixels = try Self.pixels(body.layer, width: 96, height: 96, scale: 1)
            XCTAssertEqual(pixels[(48 * 96 + 48) * 4 + 3], 0)
            XCTAssertGreaterThan(pixels[(48 * 96 + 4) * 4 + 3], 0)
            try Self.save(pixels, width: 96, name: "low-blend-frame-fallback.png")
        }
    }

    func testGradientBodiesReplaceBackdropAndReachDeclaredEnds() async throws {
        let from = CGColor(srgbRed: 0xDC / 255, green: 0xF8 / 255, blue: 0xEC / 255, alpha: 1)
        let to = CGColor(srgbRed: 0x6C / 255, green: 0xBC / 255, blue: 0x9C / 255, alpha: 1)
        var gradient = paint()
        gradient.gradient = [from, to]
        let canvas = CGRect(x: 0, y: 0, width: 96, height: 96)
        for (angle, flat, ends) in [
            (90, 1, [(48, 0), (48, 95)]),
            (0, 1, [(0, 48), (95, 48)]),
            (90, 0, [(48, 0), (48, 95)])
        ] {
            let scene = scene()
            await apply(initialCommands(rect: canvas) + [
                bodyGlass(recipe: "\(recipe)|optics:0:\(flat):\(angle)", paint: gradient)
            ], to: scene)
            try ShellLayerScene.engineQueue.sync {
                let body = try Self.native(scene.glassBodies[0])
                let sublayers = body.layer.sublayers ?? []
                XCTAssertFalse(try Self.containsBackdrop(sublayers))
                let material = try XCTUnwrap(sublayers[1] as? CAGradientLayer)
                XCTAssertNotNil(material.mask)
                XCTAssertTrue(try Self.fillIsClear(body))
                for shine in body.sdfLayers[2 ... 3] { shine.isHidden = true }
                let pixels = try Self.pixels(body.layer, width: 96, height: 96, scale: 1)
                for ((x, y), color) in zip(ends, [from, to]) {
                    Self.assertColor(pixels, x: x, y: y, equals: color, within: 3)
                }
                try Self.save(pixels, width: 96, name: "gradient-\(angle)-\(flat).png")
            }
        }
    }

    func testGradientMaterialFollowsCoverageAndRecolorsInPlace() throws {
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        try ShellLayerScene.engineQueue.sync {
            guard ShellGlassCapability.shared.available else { throw XCTSkip("Native glass is unavailable") }
            let optics = try XCTUnwrap(ShellGlassRecipe("\(recipe)|optics:0.3:0:90"))
            for staged in [false, true] {
                let body = ShellGlassBody()
                let root = CALayer()
                root.frame = CGRect(x: 0, y: 0, width: 96, height: 96)
                root.isGeometryFlipped = true
                root.addSublayer(body.layer)
                var paint = ShellLayerPaint(
                    fill: CGColor(gray: 0.1, alpha: 1), border: nil, borderWidth: 0, radius: 0, opacity: 1, scale: 1,
                    shadow: ShellLayerScene.clear, shadowRadius: 0
                )
                func apply(_ side: CGFloat, _ animation: ShellAnimation?) {
                    let rect = CGRect(x: 0, y: 0, width: side, height: side)
                    let shape = ShellGlassShape(slot: 1, kind: 0, rect: rect, radius: 0, thickness: 0)
                    body.apply(
                        size: rect.size, shapes: [shape], recipe: optics, paint: paint, animation: animation,
                        shapeAnimations: animation.map { [1: $0] }
                    )
                }
                apply(96, nil)
                let renderer = try ShellOffscreenRenderer(root: root, width: 96, height: 96)
                _ = try renderer.render(paused: CACurrentMediaTime())
                if staged { apply(48, Self.calm) }
                paint.gradient = [red, red]
                apply(48, Self.calm)
                let material = try XCTUnwrap(body.canvasLayers[1] as? CAGradientLayer)
                let key = ShellGlassBody.Channel.width.key
                let width = try XCTUnwrap(body.canvasLayers[2].animation(forKey: key) as? CASpringAnimation)
                let follower = try XCTUnwrap(material.animation(forKey: key) as? CASpringAnimation)
                XCTAssertEqual(follower.beginTime, width.beginTime)
                XCTAssertEqual(follower.fromValue as? NSNumber, width.fromValue as? NSNumber)
                let pixels = try renderer.render(paused: width.beginTime + 0.03)
                let row = (0 ..< 96).map { Array(pixels[(20 * 96 + $0) * 4 ..< (20 * 96 + $0) * 4 + 4]) }
                let drawn = row.count { $0[3] > 0 }
                XCTAssertGreaterThan(drawn, 80)
                XCTAssertGreaterThan(row.count { $0[2] > 200 && $0[1] < 80 && $0[3] > 200 } * 5, drawn * 4)
                paint.gradient = [blue, red]
                apply(48, nil)
                XCTAssertTrue(body.canvasLayers[1] === material)
                XCTAssertTrue(try CFEqual(XCTUnwrap((material.colors as? [CGColor])?.first), blue))
            }
        }
    }

    func testFlatBodyOmitsBackdropAndMaskUntilGlassReturns() async throws {
        let scene = scene()
        await apply(initialCommands() + [bodyGlass(recipe: "\(recipe)|optics:0.1:1:90")], to: scene)
        try ShellLayerScene.engineQueue.sync {
            let body = try Self.native(scene.glassBodies[0])
            XCTAssertEqual(body.layer.sublayers?.count, 5)
            XCTAssertFalse(try Self.containsBackdrop(body.layer.sublayers ?? []))
            XCTAssertNotNil(body.canvasLayers.first { $0.compositingFilter != nil })
            XCTAssertTrue(body.maskElements.isEmpty)
            XCTAssertEqual(body.elements.map(\.count), [1, 1, 1, 1, 1])
        }
        await apply([bodyGlass()], to: scene)
        try ShellLayerScene.engineQueue.sync {
            let body = try Self.native(scene.glassBodies[0])
            let sublayers = body.layer.sublayers ?? []
            XCTAssertEqual(sublayers.count, 6)
            XCTAssertEqual(body.elements.count, 4)
            XCTAssertTrue(try Self.containsBackdrop([sublayers[1]]))
            XCTAssertNotNil(sublayers[1].mask)
            XCTAssertNotNil(sublayers[1].filters)
            XCTAssertEqual(body.maskElements.count, 1)
        }
    }

    func testExplicitDefaultRimMatchesTodaysGlassExactly() async throws {
        var rendered: [[UInt8]] = []
        for recipe in [recipe, "\(recipe)|optics:0.1:0:90"] {
            let scene = scene()
            await apply(initialCommands(radius: 12) + [bodyGlass(recipe: recipe)], to: scene)
            try ShellLayerScene.engineQueue.sync {
                let body = try Self.native(scene.glassBodies[0])
                XCTAssertTrue(try Self.containsBackdrop([try XCTUnwrap(body.layer.sublayers?[1])]))
                try rendered.append(Self.pixels(body.layer, width: 96, height: 96, scale: 2))
            }
        }
        XCTAssertEqual(rendered[0], rendered[1])
    }

    func testRoleGradientResolvesThroughPaletteAndFollowsAppearance() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.glass{w=96,h=96,backdrop=false,rim=0.55,
                gradient={from='background',to='#6cbc9c',angle=90},ui.shape{w=96,h=96}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let text = ShellTextStore()
        text.ingest(wire: script.output)
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        let surface = ShellWidgetSurface(scale: 2, resources: resources, directories: [])
        let background = Color(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0,
            role: UInt16(ShellRole.background.rawValue + 1) | 255 << 8
        )
        var resolved: [CGColor] = []
        for dark in [false, true] {
            resources.palette.refresh(
                theme: .native, appearance: try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
            )
            let expected = try XCTUnwrap(resources.palette.color(background))
            surface.reset(text: text)
            XCTAssertTrue(surface.apply(script.output, text: text))
            let colors = try ShellLayerScene.engineQueue.sync {
                let body = try Self.native(surface.scene.glassBodies.values.first)
                XCTAssertFalse(try Self.containsBackdrop(body.layer.sublayers ?? []))
                let material = try XCTUnwrap(body.canvasLayers.compactMap { $0 as? CAGradientLayer }.first)
                return try XCTUnwrap(material.colors as? [CGColor])
            }
            XCTAssertEqual(colors.count, 2)
            XCTAssertTrue(CFEqual(colors[0], expected))
            XCTAssertEqual(colors[1].components?.map { Int(($0 * 255).rounded()) }, [0x6C, 0xBC, 0x9C, 255])
            resolved.append(colors[0])
        }
        XCTAssertFalse(CFEqual(resolved[0], resolved[1]))
    }

    nonisolated static func containsBackdrop(_ layers: [CALayer]) throws -> Bool {
        let backdrop = try XCTUnwrap(ShellGlassCapability.shared.backdropClass)
        return layers.contains { $0.isKind(of: backdrop) }
    }

    nonisolated static func fillIsClear(_ body: ShellGlassBody) throws -> Bool {
        let effect = try XCTUnwrap(body.sdfLayers[1].value(forKey: "effect") as? NSObject)
        return try CFEqual(XCTUnwrap(effect.value(forKey: "color")) as AnyObject, ShellLayerScene.clear)
    }

    nonisolated static func luminance(_ pixels: [UInt8], x: Int, y: Int, width: Int = 96) -> Double {
        let index = (y * width + x) * 4
        return 0.0722 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.2126 * Double(pixels[index + 2])
    }

    nonisolated static func assertColor(
        _ pixels: [UInt8], x: Int, y: Int, equals color: CGColor, within tolerance: Int, width: Int = 96,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let index = (y * width + x) * 4
        let actual = [pixels[index + 2], pixels[index + 1], pixels[index], pixels[index + 3]].map(Int.init)
        let expected = (color.components ?? []).map { Int(($0 * 255).rounded()) }
        XCTAssertEqual(expected.count, 4, file: file, line: line)
        for (value, target) in zip(actual, expected) {
            XCTAssertLessThanOrEqual(abs(value - target), tolerance, "\(actual) vs \(expected)", file: file, line: line)
        }
    }

    nonisolated static func pixels(_ layer: CALayer, width: Int, height: Int, scale: Int) throws -> [UInt8] {
        let previous = layer.superlayer
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: width, height: height)
        root.isGeometryFlipped = true
        let holder = CALayer()
        holder.anchorPoint = .zero
        holder.bounds = layer.bounds
        holder.setAffineTransform(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        root.addSublayer(holder)
        holder.addSublayer(layer)
        defer {
            layer.removeFromSuperlayer()
            previous?.insertSublayer(layer, at: 0)
        }
        return try ShellOffscreenRenderer(root: root, width: width, height: height).render()
    }

    nonisolated static func save(_ pixels: [UInt8], width: Int, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["OMNIWM_GLASS_EVIDENCE"] else { return }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let data = Data(pixels) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        let info = CGBitmapInfo.byteOrder32Little
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: width,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let target = output.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            target as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
