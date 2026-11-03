// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import IOSurface
import Metal
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellBackingScaleShaderTests: XCTestCase {
    private func program(_ source: String) throws -> ShellShaderProgram {
        _ = try XCTUnwrap(ShellShaderGPU.device)
        _ = try XCTUnwrap(ShellShaderGPU.queue)
        let program = ShellShaderProgram(name: "density fixture")
        program.finish(try ShellShaderLibrary.pipeline(Data(source.utf8), name: program.name), failure: nil)
        return program
    }

    func testInFlightDensityChangesPublishOnlyLatestPixelsAndUniforms() async throws {
        let originalScale: CGFloat = 1
        let nextScale: CGFloat = 2
        let intermediateScale: CGFloat = 3
        let pointSize = CGSize(width: 8, height: 4)
        let slot: Int32 = 0
        let program = try program("""
        float4 shade(float2 uv, constant OmniShader& shader) {
            float alpha = uv.x < 0.5 ? 0 : 1;
            return float4(shader.scale / shader.values.x * alpha, 0, 0, alpha);
        }
        """)
        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: pointSize)
        let maskLayer = CALayer()
        let host = CALayer()
        let mask = ShellLayerMask(layer: maskLayer, host: host)
        let frames = AsyncStream.makeStream(of: ShellShaderDrawer.Frame.self)
        var next = frames.stream.makeAsyncIterator()
        let drawer = ShellShaderDrawer(
            scale: originalScale, container: layer, queue: ShellLayerScene.engineQueue
        ) { frames.continuation.yield($0) }
        let input = ShellShaderInput(
            values: SIMD4(Float(nextScale), 0, 0, 0), rate: 0, colors: .init(repeating: .zero)
        )
        drawer.update(slot, layer: layer, program: program, input: input, mask: mask)
        let oldCompletion = await next.next()
        let old = try XCTUnwrap(oldCompletion)
        XCTAssertNil(old.failure)
        drawer.updateBackingScale(nextScale)
        drawer.updateBackingScale(intermediateScale)
        drawer.updateBackingScale(nextScale)
        XCTAssertNil(drawer.alpha(slot, at: .zero))
        drawer.finish(old)
        XCTAssertNil(layer.contents)
        let currentCompletion = await next.next()
        let current = try XCTUnwrap(currentCompletion)
        XCTAssertNil(current.failure)
        XCTAssertEqual(current.token, old.token)
        XCTAssertTrue(current.program === program)
        drawer.finish(current)
        let output = try XCTUnwrap(layer.contents as? IOSurface)
        XCTAssertEqual(output.width, Int((pointSize.width * nextScale).rounded(.up)))
        XCTAssertEqual(output.height, Int((pointSize.height * nextScale).rounded(.up)))
        XCTAssertTrue(maskLayer.contents as? IOSurface === output)
        let clearPoint = CGPoint(x: pointSize.width / 4, y: pointSize.height / 2)
        let opaquePoint = CGPoint(x: pointSize.width * 3 / 4, y: pointSize.height / 2)
        XCTAssertEqual(drawer.alpha(slot, at: clearPoint), 0)
        XCTAssertEqual(drawer.alpha(slot, at: opaquePoint), 1)
        output.lock(options: .readOnly, seed: nil)
        let offset = Int((opaquePoint.y * nextScale).rounded(.down)) * output.bytesPerRow
            + Int((opaquePoint.x * nextScale).rounded(.down)) * MemoryLayout<UInt32>.size
        XCTAssertEqual(output.baseAddress.load(fromByteOffset: offset, as: UInt32.self), 0xFFFF_0000)
        output.unlock(options: .readOnly, seed: nil)
        drawer.updateBackingScale(nextScale)
        XCTAssertTrue(layer.contents as? IOSurface === output)
        drawer.remove(slot)
        frames.continuation.finish()
    }

    func testLowerDensityRecoversAnEffectRejectedByThePixelLimit() async throws {
        let lowerScale: CGFloat = 1
        let higherScale: CGFloat = 2
        let size = CGSize(width: CGFloat(ShellShaderDrawer.maximumPixels) / higherScale + 1, height: 1)
        let shaderName = "density-recovery.metal"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
        #define OMNI_TEXTURE
        float4 shade(float2 uv, constant OmniShader& shader, texture2d<float> image) {
            return omni_sample(image, uv);
        }
        """.utf8).write(to: directory.appendingPathComponent(shaderName))
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        let compiled = expectation(description: "The density fixture shader finishes compiling")
        let compilationFailureDeadline: TimeInterval = 10
        resources.shaders.onChange = { compiled.fulfill() }
        let program = resources.shaders.program(source: shaderName, directories: [directory])
        await fulfillment(of: [compiled], timeout: compilationFailureDeadline)
        resources.shaders.onChange = nil
        XCTAssertNil(program.failure)
        _ = try XCTUnwrap(program.pipeline)
        let fixture = ShellBackingScaleFixture(scale: higherScale, resources: resources, directories: [directory])
        let scene = fixture.surface.scene
        let frames = AsyncStream.makeStream(of: ShellShaderDrawer.Frame.self)
        var next = frames.stream.makeAsyncIterator()
        ShellLayerScene.engineQueue.sync {
            scene.shaders = ShellShaderDrawer(
                scale: higherScale,
                container: scene.container,
                queue: ShellLayerScene.engineQueue
            ) {
                frames.continuation.yield($0)
            }
        }
        var root = ShellBackingScaleFixture.node(.group, size: size)
        root.subtree_end = 1
        root.effect_ref = 1
        fixture.apply([root], strings: ["effect:0:0:0:0:0:0:" + shaderName])
        await fixture.complete()
        let handle = fixture.surface.layout.core.rootHandle
        let source = try ShellLayerScene.engineQueue.sync {
            XCTAssertEqual(scene.effects[handle.slot]?.failed, true)
            return try XCTUnwrap(scene.layers[handle.slot])
        }
        XCTAssertTrue(fixture.surface.updateDisplayContext(scale: lowerScale))
        await fixture.complete()
        let completed = await next.next()
        let frame = try XCTUnwrap(completed)
        XCTAssertNil(frame.failure)
        try ShellLayerScene.engineQueue.sync {
            scene.shaders?.finish(frame)
            let effect = try XCTUnwrap(scene.effects[handle.slot])
            XCTAssertFalse(effect.failed)
            XCTAssertTrue(effect.source === source)
            let output = try XCTUnwrap(effect.output.contents as? IOSurface)
            XCTAssertEqual(output.width, Int((size.width * lowerScale).rounded(.up)))
            XCTAssertEqual(output.height, Int((size.height * lowerScale).rounded(.up)))
        }
        XCTAssertTrue(fixture.surface.scene === scene)
        XCTAssertEqual(fixture.surface.layout.core.rootHandle, handle)
        await ShellBackingScaleFixture.submit([.remove(slot: handle.slot)], to: scene)
        frames.continuation.finish()
    }

    func testGroupDensityRetainsSourceAndRebindsDisplayAfterOldFrameCompletes() async throws {
        let originalScale: CGFloat = 1
        let nextScale: CGFloat = 2
        let pointSize = CGSize(width: 12, height: 8)
        let bleed: CGFloat = 2
        let originalDisplay = UInt32.max - 10
        let destinationDisplay = originalDisplay + 1
        let slot: Int32 = 0
        let program = try program("""
        #define OMNI_TEXTURE
        float4 shade(float2 uv, constant OmniShader& shader, texture2d<float> image) {
            return omni_sample(image, uv);
        }
        """)
        let shader = ShellShaderInput(values: .zero, rate: 0, colors: .init(repeating: .zero))
        let input = ShellGroupEffectInput(program: program, shader: shader, bleed: bleed, display: originalDisplay)
        let container = CALayer()
        let source = CALayer()
        source.anchorPoint = .zero
        source.bounds = CGRect(origin: .zero, size: pointSize)
        source.backgroundColor = CGColor(gray: 1, alpha: 1)
        container.addSublayer(source)
        let group = ShellGroupEffect(source: source, scale: originalScale, input: input)
        group.attach()
        let sourceHost = source.superlayer
        let output = group.output
        let frames = AsyncStream.makeStream(of: ShellShaderDrawer.Frame.self)
        var next = frames.stream.makeAsyncIterator()
        let drawer = ShellShaderDrawer(
            scale: originalScale, container: container, queue: ShellLayerScene.engineQueue
        ) { frames.continuation.yield($0) }
        drawer.updateGroup(slot, group: group)
        drawer.redrawGroups()
        let oldCompletion = await next.next()
        let old = try XCTUnwrap(oldCompletion)
        XCTAssertNil(old.failure)
        let oldResources = try XCTUnwrap(group.resources)
        group.updateBackingScale(nextScale)
        group.update(ShellGroupEffectInput(program: program, shader: shader, bleed: bleed, display: destinationDisplay))
        drawer.updateBackingScale(nextScale)
        drawer.updateGroup(slot, group: group)
        drawer.redrawGroups()
        XCTAssertNil(group.resources)
        drawer.finish(old)
        XCTAssertNil(output.contents)
        let currentCompletion = await next.next()
        let current = try XCTUnwrap(currentCompletion)
        XCTAssertNil(current.failure)
        drawer.finish(current)
        let resources = try XCTUnwrap(group.resources)
        let width = Int(((pointSize.width + 2 * bleed) * nextScale).rounded(.up))
        let height = Int(((pointSize.height + 2 * bleed) * nextScale).rounded(.up))
        XCTAssertEqual(resources.source.width, width)
        XCTAssertEqual(resources.source.height, height)
        XCTAssertEqual(resources.lease.display, destinationDisplay)
        XCTAssertEqual(resources.lease.bytes, resources.backing.reduce(0) { $0 + $1.allocationSize })
        XCTAssertTrue(group.source === source)
        XCTAssertTrue(source.superlayer === sourceHost)
        XCTAssertTrue(group.output === output)
        XCTAssertFalse(resources.source === oldResources.source)
        XCTAssertEqual(output.contentsScale, nextScale)
        let displayed = try XCTUnwrap(output.contents as? IOSurface)
        XCTAssertEqual(displayed.width, width)
        XCTAssertEqual(displayed.height, height)
        group.updateBackingScale(nextScale)
        drawer.updateBackingScale(nextScale)
        XCTAssertTrue(group.resources?.source === resources.source)
        group.restore()
        drawer.remove(slot)
        frames.continuation.finish()
    }
}
