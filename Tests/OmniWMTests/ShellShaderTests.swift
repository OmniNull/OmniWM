// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import IOSurface
import Metal
@testable import OmniWM
import OmniWMScriptHost
import QuartzCore
import XCTest

@MainActor
final class ShellShaderTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        guard ShellShaderGPU.device != nil else { throw XCTSkip("Metal is not available") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func compiled(_ name: String, _ source: String) async throws -> ShellShaderProgram {
        try Data(source.utf8).write(to: directory.appendingPathComponent(name))
        let library = ShellShaderLibrary()
        let program = library.program(source: name, directories: [directory])
        await until { !program.isCompiling }
        return program
    }

    private nonisolated static func pixel(
        _ pipeline: any MTLRenderPipelineState,
        _ uniforms: ShellShaderUniforms
    ) throws -> [UInt8] {
        let device = try XCTUnwrap(ShellShaderGPU.device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let buffer = try XCTUnwrap(ShellShaderGPU.queue?.makeCommandBuffer())
        let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShellShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        var pixel: [UInt8] = [0, 0, 0, 0]
        texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        return pixel
    }

    func testShaderRendersIntoTheLayer() async throws {
        executionTimeAllowance = 60
        let program = try await compiled("solid.metal", """
        float4 shade(float2 uv, constant OmniShader& shader) {
            return float4(shader.values.x, 0, 0, 1);
        }
        """)
        XCTAssertNotNil(program.pipeline)

        let container = CALayer()
        let scene = ShellLayerScene(container: container, scale: 1)
        let input = ShellShaderInput(values: SIMD4(1, 0, 0, 0), rate: 0, colors: .init(repeating: .zero))
        scene.submit([
            .insert(slot: 0, parent: -1, kind: .shader, after: -1),
            .frame(slot: 0, rect: CGRect(x: 0, y: 0, width: 4, height: 4), animation: nil),
            .shader(slot: 0, program: program, input: input)
        ], animated: false)
        var surface: IOSurface?
        for _ in 0 ..< 400 where surface == nil {
            try await Task.sleep(for: .milliseconds(5))
            surface = ShellLayerScene.engineQueue.sync { container.sublayers?.first?.contents as? IOSurface }
        }
        let rendered = try XCTUnwrap(surface)
        rendered.lock(options: .readOnly, seed: nil)
        let pixel = rendered.baseAddress.load(as: UInt32.self)
        rendered.unlock(options: .readOnly, seed: nil)
        XCTAssertEqual(pixel, 0xFFFF_0000)
    }

    func testAMaskShadersFramesShapeItsStackAndAFailureUnmasksIt() async throws {
        executionTimeAllowance = 60
        let program = try await compiled("half.metal", """
        float4 shade(float2 uv, constant OmniShader& shader) {
            return float4(1, 1, 1, uv.x < 0.5 ? 1 : 0);
        }
        """)
        let container = CALayer()
        let scene = ShellLayerScene(container: container, scale: 1)
        let input = ShellShaderInput(values: .zero, rate: 0, colors: .init(repeating: .zero))
        let paint = { (masks: Bool) in
            ShellLayerPaint(
                fill: nil,
                border: nil,
                borderWidth: 0,
                radius: 0,
                opacity: 1,
                scale: 1,
                shadow: nil,
                shadowRadius: 0,
                masks: masks
            )
        }
        scene.submit([
            .insert(slot: 0, parent: -1, kind: .group, after: -1),
            .frame(slot: 0, rect: CGRect(x: 0, y: 0, width: 8, height: 4), animation: nil),
            .insert(slot: 1, parent: 0, kind: .shader, after: -1),
            .frame(slot: 1, rect: CGRect(x: 0, y: 0, width: 8, height: 4), animation: nil),
            .paint(slot: 1, paint(true), animation: nil),
            .shader(slot: 1, program: program, input: input)
        ], animated: false)
        let host = try XCTUnwrap(ShellLayerScene.engineQueue.sync { container.sublayers?.first })
        var shape: IOSurface?
        for _ in 0 ..< 400 where shape == nil {
            try await Task.sleep(for: .milliseconds(5))
            shape = ShellLayerScene.engineQueue.sync { host.mask?.contents as? IOSurface }
        }
        XCTAssertNotNil(shape)
        ShellLayerScene.engineQueue.sync {
            let shader = host.sublayers?.first
            XCTAssertEqual(shader?.isHidden, true)
            XCTAssertTrue(host.mask?.contents as AnyObject? === shader?.contents as AnyObject?)
            XCTAssertEqual(host.mask?.bounds.size, CGSize(width: 8, height: 4))
        }

        scene.submit([
            .shader(slot: 1, program: ShellShaderProgram(name: "broken.metal", failure: "broken"), input: input)
        ], animated: false)
        ShellLayerScene.engineQueue.sync {
            XCTAssertNil(host.mask)
        }

        scene.submit([.paint(slot: 1, paint(false), animation: nil)], animated: false)
        ShellLayerScene.engineQueue.sync {
            XCTAssertNil(host.mask)
            XCTAssertEqual(host.sublayers?.first?.isHidden, false)
        }
    }

    func testTransitionsInterpolateAndSettleWhenShadersDoNotAnimate() {
        let opening = ShellShaderTransition(from: 0, to: 1, start: 10, duration: 2)
        XCTAssertEqual(opening.progress(at: 9), 0)
        XCTAssertEqual(opening.progress(at: 11), 0.5)
        XCTAssertEqual(opening.progress(at: 20), 1)
        XCTAssertEqual(ShellShaderTransition(from: 0.6, to: 0, start: 0, duration: 0).progress(at: 0), 0)

        let colors = ShellShaderInput.Colors(repeating: .zero)
        let still = ShellShaderInput(values: .zero, rate: 0, colors: colors).uniforms(
            size: CGSize(width: 4, height: 2),
            scale: 2,
            elapsed: 3,
            now: 11,
            transition: opening
        )
        XCTAssertEqual(still.time, 0)
        XCTAssertEqual(still.progress, 1)
        let moving = ShellShaderInput(values: .zero, rate: 30, colors: colors).uniforms(
            size: CGSize(width: 4, height: 2),
            scale: 2,
            elapsed: 3,
            now: 11,
            transition: opening
        )
        XCTAssertEqual(moving.time, 3)
        XCTAssertEqual(moving.progress, 0.5)
    }

    func testWidgetSecondsDriveProgressExactlyWhateverTheShaderRate() {
        let opening = ShellShaderTransition.opening(ShellTiming(open: 0.75), standard: 0.35, at: 10)
        XCTAssertEqual(opening, ShellShaderTransition(from: 0, to: 1, start: 10, duration: 0.75, forced: true))
        XCTAssertTrue(opening.drivesFrames(at: 10.5))
        XCTAssertFalse(opening.drivesFrames(at: 10.75))
        let standard = ShellShaderTransition.opening(ShellTiming(), standard: 0.35, at: 10)
        XCTAssertEqual(standard, ShellShaderTransition(from: 0, to: 1, start: 10, duration: 0.35))
        XCTAssertFalse(standard.drivesFrames(at: 10.1))
        XCTAssertEqual(ShellShaderTransition.opening(ShellTiming(), standard: nil, at: 10).duration, 0)
        let closing = ShellShaderTransition.closing(from: 0.5, ShellTiming(close: 0.5), standard: nil, at: 20)
        XCTAssertEqual(closing.duration, 0.25)
        XCTAssertTrue(closing.forced)
        XCTAssertEqual(ShellShaderTransition.closing(from: 0.5, ShellTiming(), standard: 0.12, at: 20).duration, 0.12)

        let uniforms = ShellShaderInput(values: .zero, rate: 0, colors: ShellShaderInput.Colors(repeating: .zero))
            .uniforms(
                size: CGSize(width: 4, height: 2),
                scale: 2,
                elapsed: 3,
                now: 10.375,
                transition: opening
            )
        XCTAssertEqual(uniforms.time, 0)
        XCTAssertEqual(uniforms.progress, 0.5)
    }

    func testWidgetsDeclareOpenAndCloseSecondsOnTheirRoot() throws {
        let widget = try ShellRenderedWidget(name: "timing", source: """
        function render(ctx) return ui.box{ w = 1, h = 1 } end
        function popout(ctx)
            return ui.column{ open = 0.8, close = 99, ui.box{ w = 4, h = 4, open = -2 } }
        end
        """)
        let tree = widget.renderPopout()
        XCTAssertEqual(tree.map(\.content.openDuration), [0.8, 0])
        XCTAssertEqual(tree.map(\.content.closeDuration), [30, -1])
        XCTAssertEqual(ShellWireDecoder.rootTiming(widget.output(OMNI_VIEW_POPOUT)), ShellTiming(open: 0.8, close: 30))
        widget.render(ShellBarData())
        XCTAssertEqual(ShellWireDecoder.rootTiming(widget.output()), ShellTiming())
    }

    func testShadersReadProgressAfterThePalette() async throws {
        executionTimeAllowance = 60
        let program = try await compiled("progress.metal", """
        float4 shade(float2 uv, constant OmniShader& shader) {
            return float4(shader.progress, shader.values.w, shader.colors[15].z, 1);
        }
        """)
        let pipeline = try XCTUnwrap(program.pipeline)
        var colors = ShellShaderInput.Colors(repeating: .zero)
        colors[15] = SIMD4(0, 0, 0.6, 1)
        let uniforms = ShellShaderInput(values: SIMD4(0, 0, 0, 0.4), rate: 0, colors: colors).uniforms(
            size: CGSize(width: 1, height: 1),
            scale: 1,
            elapsed: 0,
            now: 0,
            transition: ShellShaderTransition(from: 0, to: 0.2, start: 0, duration: 1)
        )
        let pixel = try Self.pixel(pipeline, uniforms)
        XCTAssertEqual(pixel, [153, 102, 51, 255])
    }

    func testShadersReadTheirAnchorAndContentAfterProgress() async throws {
        executionTimeAllowance = 60
        let program = try await compiled("stage.metal", """
        float4 shade(float2 uv, constant OmniShader& shader) {
            return float4(shader.anchor.x / 10.0, shader.anchor.y / 10.0, shader.content.z / 10.0, 1);
        }
        """)
        let pipeline = try XCTUnwrap(program.pipeline)
        let uniforms = ShellShaderInput(values: .zero, rate: 0, colors: .init(repeating: .zero)).uniforms(
            size: CGSize(width: 1, height: 1),
            scale: 1,
            elapsed: 0,
            now: 0,
            transition: .settled,
            stage: ShellShaderStage(anchor: CGPoint(x: 2, y: 4), content: CGRect(x: 0, y: 0, width: 6, height: 1))
        )
        XCTAssertEqual(try Self.pixel(pipeline, uniforms), [153, 102, 51, 255])
    }

    func testAudioShadersReadTheSpectrumBarsAfterTheContent() async throws {
        executionTimeAllowance = 60
        XCTAssertEqual(MemoryLayout<ShellShaderUniforms>.offset(of: \ShellShaderUniforms.audio), 704)
        XCTAssertEqual(MemoryLayout<ShellShaderUniforms>.stride, 944)
        let program = try await compiled("bars.metal", """
        float4 shade(float2 uv, constant OmniShader& shader) {
            return float4(shader.audio[0], shader.audio[59], shader.content.z / 10.0, 1);
        }
        """)
        let pipeline = try XCTUnwrap(program.pipeline)
        var bars = ShellSpectrumBands.Bars(repeating: 0)
        bars[0] = 0.2
        bars[59] = 0.6
        let input = ShellShaderInput(values: .zero, rate: 0, colors: .init(repeating: .zero), audio: true)
        let uniforms = input.uniforms(
            size: CGSize(width: 4, height: 1),
            scale: 1,
            elapsed: 0,
            now: 0,
            transition: .settled,
            audio: bars
        )
        XCTAssertEqual(try Self.pixel(pipeline, uniforms), [102, 153, 51, 255])
        let silent = input.uniforms(
            size: CGSize(width: 4, height: 1),
            scale: 1,
            elapsed: 0,
            now: 0,
            transition: .settled
        )
        XCTAssertEqual(try Self.pixel(pipeline, silent), [102, 0, 0, 255])
    }

    func testTheBundledLiquidShaderGrowsFromItsAnchorIntoTheContent() async throws {
        executionTimeAllowance = 60
        let bundled = try XCTUnwrap(ShellDefaults.bundledFile("shaders/liquid.metal"))
        let program = try await compiled("liquid.metal", String(contentsOf: bundled, encoding: .utf8))
        let pipeline = try XCTUnwrap(program.pipeline, program.failure ?? "")
        var colors = ShellShaderInput.Colors(repeating: .zero)
        colors[ShellRole.elevatedSurface.rawValue] = SIMD4(1, 1, 1, 1)
        let alpha = { (progress: Float) in
            try Self.pixel(pipeline, ShellShaderInput(values: .zero, rate: 0, colors: colors).uniforms(
                size: CGSize(width: 100, height: 60),
                scale: 1,
                elapsed: 0,
                now: 0,
                transition: ShellShaderTransition(from: 0, to: progress, start: 0, duration: 0),
                stage: ShellShaderStage(
                    anchor: CGPoint(x: 50, y: -20),
                    content: CGRect(x: 0, y: 0, width: 100, height: 60)
                )
            ))[3]
        }
        XCTAssertEqual(try alpha(0), 0)
        XCTAssertEqual(try alpha(1), 255)
    }

    func testTheBundledMeterShaderFillsACapsuleWithItsTintGradient() async throws {
        executionTimeAllowance = 60
        let bundled = try XCTUnwrap(ShellDefaults.bundledFile("shaders/meter.metal"))
        let program = try await compiled("meter.metal", String(contentsOf: bundled, encoding: .utf8))
        let pipeline = try XCTUnwrap(program.pipeline, program.failure ?? "")
        var colors = ShellShaderInput.Colors(repeating: .zero)
        colors[ShellRole.green.rawValue] = SIMD4(0, 0.5, 0, 1)
        let pixel = { (width: CGFloat) in
            try Self.pixel(pipeline, ShellShaderInput(values: SIMD4(2, 0, 0, 0), rate: 0, colors: colors).uniforms(
                size: CGSize(width: width, height: 6),
                scale: 1,
                elapsed: 0,
                now: 0,
                transition: .settled,
                stage: ShellShaderStage(anchor: .zero, content: .zero)
            ))
        }
        let center = try pixel(100)
        XCTAssertEqual(Double(center[1]), 150, accuracy: 2)
        XCTAssertEqual(Double(center[2]), 13, accuracy: 2)
        XCTAssertEqual(center[3], 255)
    }

    func effectPipeline(_ name: String) async throws -> any MTLRenderPipelineState {
        let file = "effects-\(name).metal"
        let source = try String(contentsOf: XCTUnwrap(ShellDefaults.bundledFile("shaders/" + file)), encoding: .utf8)
        let program = try await compiled(file, source)
        return try XCTUnwrap(program.pipeline, program.failure ?? file)
    }

    func effectImage(
        _ pipeline: any MTLRenderPipelineState,
        values: SIMD4<Float>,
        progress: Float = 1,
        time: Double = 0,
        texture: (any MTLTexture)? = nil
    ) throws -> [UInt8] {
        var colors = ShellShaderInput.Colors(repeating: .zero)
        colors[ShellRole.accent.rawValue] = SIMD4(1, 0.2, 0.1, 1)
        colors[ShellRole.purple.rawValue] = SIMD4(0.2, 0.1, 1, 1)
        let uniforms = ShellShaderInput(values: values, rate: 30, colors: colors).uniforms(
            size: CGSize(width: 80, height: 40), scale: 1, elapsed: time, now: 0,
            transition: ShellShaderTransition(from: 0, to: progress, start: 0, duration: 0)
        )
        return try Self.pixels(pipeline, uniforms, width: 80, height: 40, source: texture)
    }

    func testEffectMasksHaveCompleteEndpointsAndMonotonicReveal() async throws {
        for (name, values) in [
            ("circle", SIMD4<Float>(0.5, 0.5, 1, -1)),
            ("wipe", SIMD4<Float>(1, 0, 1, -1)),
            ("dissolve", SIMD4<Float>(8, 1, 0, -1)),
            ("burn", SIMD4<Float>(26, 0.015, 0, -1)),
            ("smoke", SIMD4<Float>(60, 0.14, 0, -1))
        ] {
            let pipeline = try await effectPipeline(name)
            let closed = try effectImage(pipeline, values: values, progress: 0)
            let opened = try effectImage(pipeline, values: values, progress: 1)
            XCTAssertTrue(closed.allSatisfy { $0 == 0 }, name)
            XCTAssertTrue(opened.allSatisfy { $0 == 255 }, name)
            let early = try effectImage(pipeline, values: values, progress: 0.25)
            let late = try effectImage(pipeline, values: values, progress: 0.75)
            let alpha = stride(from: 3, to: early.count, by: 4)
            XCTAssertTrue(alpha.allSatisfy { early[$0] <= late[$0] }, name)
            XCTAssertTrue(alpha.contains { early[$0] > 0 }, name)
            XCTAssertTrue(alpha.contains { late[$0] < 255 }, name)
            var manual = values
            manual.w = 0.25
            XCTAssertEqual(try effectImage(pipeline, values: manual, progress: 1), early, name)
        }
    }

    func testCircleUsesPointDistancesAndWipeRespectsDirection() async throws {
        let circle = try await effectPipeline("circle")
        let revealed = try effectImage(circle, values: SIMD4(0.5, 0.5, 1, 0.25))
        XCTAssertEqual(revealed[(20 * 80 + 40) * 4 + 3], 255)
        XCTAssertEqual(revealed[(2 * 80 + 2) * 4 + 3], 0)
        XCTAssertEqual(revealed[(20 * 80 + 56) * 4 + 3], 0)
        let wipe = try await effectPipeline("wipe")
        let left = try effectImage(wipe, values: SIMD4(1, 0, 1, 0.5))
        let right = try effectImage(wipe, values: SIMD4(-1, 0, 1, 0.5))
        XCTAssertEqual(left[(20 * 80 + 10) * 4 + 3], 255)
        XCTAssertEqual(left[(20 * 80 + 70) * 4 + 3], 0)
        XCTAssertEqual(right[(20 * 80 + 10) * 4 + 3], 0)
        XCTAssertEqual(right[(20 * 80 + 70) * 4 + 3], 255)
    }

    func testGlowAndGradientRingLeaveTheCenterAndOutsideCornersClear() async throws {
        let ring = try await effectPipeline("ring")
        let outline = try effectImage(ring, values: SIMD4(10, 3, 0, 1))
        XCTAssertEqual(outline[(20 * 80 + 40) * 4 + 3], 0)
        XCTAssertEqual(outline[3], 0)
        XCTAssertEqual(outline[(20 * 80 + 1) * 4 + 3], 255)
        XCTAssertGreaterThan(outline[(20 * 80 + 1) * 4 + 2], outline[(20 * 80 + 78) * 4 + 2])
        let glow = try await effectPipeline("glow")
        let strong = try effectImage(glow, values: SIMD4(10, 8, 1, 2))
        let soft = try effectImage(glow, values: SIMD4(10, 8, 0.3, 2))
        XCTAssertEqual(strong[3], 0)
        XCTAssertEqual(strong[(20 * 80 + 40) * 4 + 3], 0)
        XCTAssertGreaterThan(strong[(20 * 80 + 1) * 4 + 3], soft[(20 * 80 + 1) * 4 + 3])
    }

    func testAuroraMovesWhileSheenIsStaticAndBothHonorStrength() async throws {
        for (name, moving) in [("aurora", true), ("sheen", false)] {
            let pipeline = try await effectPipeline(name)
            let first = try effectImage(pipeline, values: SIMD4(0.7, 1, 0, 0))
            let later = try effectImage(pipeline, values: SIMD4(0.7, 1, 0, 0), time: 3)
            XCTAssertTrue(stride(from: 3, to: first.count, by: 4).contains { first[$0] > 0 }, name)
            XCTAssertEqual(first != later, moving, name)
            XCTAssertTrue(try effectImage(pipeline, values: SIMD4(0, 1, 0, 0)).allSatisfy { $0 == 0 }, name)
            for index in stride(from: 0, to: first.count, by: 4) {
                XCTAssertLessThanOrEqual(first[index], first[index + 3], name)
                XCTAssertLessThanOrEqual(first[index + 1], first[index + 3], name)
                XCTAssertLessThanOrEqual(first[index + 2], first[index + 3], name)
            }
        }
    }

    nonisolated static func pixels(
        _ pipeline: any MTLRenderPipelineState,
        _ uniforms: ShellShaderUniforms,
        width: Int,
        height: Int,
        source: (any MTLTexture)? = nil
    ) throws -> [UInt8] {
        let device = try XCTUnwrap(ShellShaderGPU.device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let buffer = try XCTUnwrap(ShellShaderGPU.queue?.makeCommandBuffer())
        let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShellShaderUniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertEqual(buffer.status, .completed, buffer.error?.localizedDescription ?? "")
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return bytes
    }

    func testCelestialsVisualizerDrawsEachBarOutFromTheCoverAsLongAsItsLevel() async throws {
        executionTimeAllowance = 60
        let styles = try XCTUnwrap(ShellDefaults.bundledStyles)
        let source = try String(
            contentsOf: styles.appendingPathComponent("celestial/shaders/visualizer.metal"),
            encoding: .utf8
        )
        let program = try await compiled("visualizer.metal", source)
        let pipeline = try XCTUnwrap(program.pipeline, program.failure ?? "")
        var colors = ShellShaderInput.Colors(repeating: .zero)
        colors[ShellRole.accent.rawValue] = SIMD4(1, 0, 0, 1)
        var bars = ShellSpectrumBands.Bars(repeating: 0)
        bars[0] = 1
        bars[15] = 0
        let uniforms = ShellShaderInput(values: SIMD4(20, 20, 4, 0), rate: 30, colors: colors, audio: true).uniforms(
            size: CGSize(width: 100, height: 100),
            scale: 1,
            elapsed: 0,
            now: 0,
            transition: .settled,
            audio: bars
        )
        let image = try Self.pixels(pipeline, uniforms, width: 100, height: 100)
        let pixel = { (x: Int, y: Int) in Array(image[(y * 100 + x) * 4 ..< (y * 100 + x) * 4 + 4]) }
        XCTAssertEqual(pixel(80, 50), [0, 0, 255, 255])
        XCTAssertEqual(pixel(50, 80), [0, 0, 0, 0])
        XCTAssertEqual(pixel(50, 50), [0, 0, 0, 0])
    }

    func testLakeWaveformUsesActualAudioBandsForBarCoverage() async throws {
        executionTimeAllowance = 60
        let styles = try XCTUnwrap(ShellDefaults.bundledStyles)
        let source = try String(
            contentsOf: styles.appendingPathComponent("lake/widgets/media/waveform.metal"),
            encoding: .utf8
        )
        let program = try await compiled("waveform.metal", source)
        let pipeline = try XCTUnwrap(program.pipeline, program.failure ?? "")
        let render = { (bars: ShellSpectrumBands.Bars) in
            let uniforms = ShellShaderInput(
                values: .zero, rate: 30, colors: .init(repeating: .zero), audio: true
            ).uniforms(
                size: CGSize(width: 36, height: 20),
                scale: 1,
                elapsed: 0,
                now: 0,
                transition: .settled,
                audio: bars
            )
            return try Self.pixels(pipeline, uniforms, width: 36, height: 20)
        }
        var bars = ShellSpectrumBands.Bars(repeating: 0)
        let silent = try render(bars)
        bars[0] = 1
        bars[59] = 1
        let active = try render(bars)
        let alpha = { (image: [UInt8], x: Int, y: Int) in image[(y * 36 + x) * 4 + 3] }
        XCTAssertEqual(alpha(silent, 2, 3), 0)
        XCTAssertEqual(alpha(silent, 32, 3), 0)
        XCTAssertEqual(alpha(active, 2, 3), 255)
        XCTAssertEqual(alpha(active, 32, 3), 255)
        XCTAssertEqual(alpha(active, 14, 3), 0)
        XCTAssertEqual(alpha(active, 5, 9), 0)
        XCTAssertEqual(alpha(silent, 2, 9), 255)
        let coverage = { (image: [UInt8]) in
            stride(from: 3, to: image.count, by: 4).filter { image[$0] >= 128 }.count
        }
        XCTAssertGreaterThan(coverage(active), coverage(silent))
    }

    func testCompileErrorsNameTheFileAndLine() async throws {
        executionTimeAllowance = 60
        let program = try await compiled("broken.metal", """
        float4 shade(float2 uv, constant OmniShader& shader) {
            return undefined_value;
        }
        """)
        XCTAssertNil(program.pipeline)
        let failure = try XCTUnwrap(program.failure)
        XCTAssertTrue(failure.contains("broken.metal:2"), failure)
    }

    func testSourcesMustBePlainFileNamesThatExist() {
        let library = ShellShaderLibrary()
        XCTAssertNotNil(library.program(source: "../escape.metal", directories: [directory]).failure)
        XCTAssertNotNil(library.program(source: "missing.metal", directories: [directory]).failure)
    }
}
