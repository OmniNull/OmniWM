// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import IOSurface
import Metal
@testable import OmniWM
import QuartzCore
import XCTest

extension ShellShaderTests {
    private func testTexture() throws -> any MTLTexture {
        var bytes = [UInt8](repeating: 0, count: 80 * 40 * 4)
        for y in 0 ..< 40 {
            for x in 0 ..< 80 {
                let i = (y * 80 + x) * 4
                bytes[i] = UInt8(x * 3)
                bytes[i + 1] = UInt8(y * 6)
                bytes[i + 2] = 40
                bytes[i + 3] = 255
                if x >= 60, y < 10 {
                    bytes.replaceSubrange(i ..< i + 4, with: [128, 0, 0, 128])
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 80, height: 40, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 320,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        return try XCTUnwrap(ShellShaderTexture.make(image))
    }

    func testTextureEffectsPreserveIdentityOrientationAndPremultipliedAlpha() async throws {
        let texture = try testTexture()
        for name in ["pixelate", "genie"] {
            let pipeline = try await effectPipeline(name)
            let closed = try effectImage(pipeline, values: SIMD4(0.5, 0, 0, 0), texture: texture)
            XCTAssertTrue(closed.allSatisfy { $0 == 0 }, name)
            let image = try effectImage(pipeline, values: SIMD4(0.5, 0, 0, 1), texture: texture)
            let pixel = { (x: Int, y: Int) in Array(image[(y * 80 + x) * 4 ..< (y * 80 + x) * 4 + 4]) }
            XCTAssertEqual(pixel(70, 5), [0, 0, 128, 128], name)
            XCTAssertEqual(pixel(20, 30), [40, 180, 60, 255], name)
            XCTAssertEqual(pixel(20, 5), [40, 30, 60, 255], name)
            XCTAssertEqual(try effectImage(pipeline, values: SIMD4(0.5, 0, 0, -1), texture: texture), image)
        }
    }

    func testPixelationSamplesBlocksAndGeniePinchesTowardTheAnchor() async throws {
        let texture = try testTexture()
        let pixelate = try await effectPipeline("pixelate")
        let blocks = try effectImage(pixelate, values: SIMD4(40, 0, 0, 0.5), texture: texture)
        let pixel = { (image: [UInt8], x: Int, y: Int) in Array(image[(y * 80 + x) * 4 ..< (y * 80 + x) * 4 + 4]) }
        XCTAssertEqual(pixel(blocks, 2, 2), pixel(blocks, 8, 8))
        XCTAssertNotEqual(pixel(blocks, 2, 2), pixel(blocks, 12, 2))
        let genie = try await effectPipeline("genie")
        let warped = try effectImage(genie, values: SIMD4(0.5, 0, 0, 0.5), texture: texture)
        XCTAssertEqual(pixel(warped, 40, 10), [0, 0, 0, 0])
        XCTAssertGreaterThan(pixel(warped, 40, 30)[3], 0)
        let coverage = { (y: Int) in (0 ..< 80).filter { warped[(y * 80 + $0) * 4 + 3] > 0 }.count }
        XCTAssertGreaterThan(coverage(21), coverage(38))
        let left = try effectImage(genie, values: SIMD4(0, 0, 0, 0.3), texture: texture)
        let right = try effectImage(genie, values: SIMD4(1, 0, 0, 0.3), texture: texture)
        XCTAssertGreaterThan(pixel(left, 15, 35)[3], pixel(right, 15, 35)[3])
        let top = try effectImage(genie, values: SIMD4(0.5, 1, 0, 0.5), texture: texture)
        XCTAssertGreaterThan(pixel(top, 40, 10)[3], 0)
        XCTAssertEqual(pixel(top, 40, 30), [0, 0, 0, 0])
    }

    func testSmallOpaqueTextureStaysOpaqueWhenStretched() async throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let texture = try XCTUnwrap(ShellShaderTexture.make(context.makeImage()))
        for name in ["pixelate", "genie"] {
            let pipeline = try await effectPipeline(name)
            let image = try effectImage(pipeline, values: SIMD4(48, 0, 0, 1), texture: texture)
            XCTAssertTrue(stride(from: 3, to: image.count, by: 4).allSatisfy { image[$0] == 255 }, name)
        }
    }

    func testRotatingBorderMovesAndBurnSmokeEdgesDisappearAtEndpoints() async throws {
        let rotating = try await effectPipeline("rotating-border")
        let first = try effectImage(rotating, values: SIMD4(10, 3, 90, 1))
        let later = try effectImage(rotating, values: SIMD4(10, 3, 90, 1), time: 1)
        XCTAssertNotEqual(first, later)
        XCTAssertEqual(first[(20 * 80 + 40) * 4 + 3], 0)
        XCTAssertEqual(first[3], 0)
        for name in ["burn", "smoke"] {
            let pipeline = try await effectPipeline(name)
            for progress: Float in [0, 1] {
                XCTAssertTrue(try effectImage(pipeline, values: SIMD4(26, 0.1, 1, progress)).allSatisfy { $0 == 0 })
            }
            let edge = try effectImage(pipeline, values: SIMD4(26, 0.1, 1, 0.5))
            XCTAssertTrue(stride(from: 3, to: edge.count, by: 4).contains { edge[$0] > 0 }, name)
            let loop = try effectImage(pipeline, values: SIMD4(26, 0.1, 0, -2), time: 1.5)
            XCTAssertTrue(loop.allSatisfy { $0 == 255 }, name)
        }
    }

    func testStaleFramesDoNotPublishOrBypassTheGPUBudget() async throws {
        let pipeline = try await effectPipeline("genie")
        let program = ShellShaderProgram(name: "genie")
        program.finish(pipeline, failure: nil)
        let frames = AsyncStream.makeStream(of: ShellShaderDrawer.Frame.self)
        var next = frames.stream.makeAsyncIterator()
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 8, height: 4)
        let drawer = ShellShaderDrawer(
            scale: 1, container: layer, queue: DispatchSerialQueue(label: "test.shader.frames")
        ) { frames.continuation.yield($0) }
        var input = ShellShaderInput(values: SIMD4(0.5, 0, 0, 1), rate: 0, colors: .init(repeating: .zero))
        drawer.update(0, layer: layer, program: program, input: input)
        for index in 0 ..< 3 {
            let completed = await next.next()
            let frame = try XCTUnwrap(completed)
            input.values.x = Float(index) / 3
            drawer.update(0, layer: layer, program: program, input: input)
            drawer.finish(.init(
                slot: frame.slot, token: frame.token, index: frame.index, program: frame.program,
                revision: frame.revision, failure: nil, duration: ShellShaderDrawer.frameBudget + 0.001
            ))
            XCTAssertNil(layer.contents)
        }
        XCTAssertTrue(program.failure?.contains("over the 8 ms budget") == true)
        drawer.remove(0)
        frames.continuation.finish()
    }

    func testTextureReplacementCoalescesAndRemovedSlotsRejectOldFrames() async throws {
        let pipeline = try await effectPipeline("pixelate")
        let program = ShellShaderProgram(name: "pixelate")
        program.finish(pipeline, failure: nil)
        let frames = AsyncStream.makeStream(of: ShellShaderDrawer.Frame.self)
        var next = frames.stream.makeAsyncIterator()
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 8, height: 4)
        let drawer = ShellShaderDrawer(
            scale: 1, container: layer, queue: DispatchSerialQueue(label: "test.shader.replacement")
        ) { frames.continuation.yield($0) }
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        var input = ShellShaderInput(
            values: SIMD4(48, 0, 0, 1),
            rate: 0,
            colors: .init(repeating: .zero),
            image: context.makeImage()
        )
        drawer.update(0, layer: layer, program: program, input: input)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        input.image = context.makeImage()
        drawer.update(0, layer: layer, program: program, input: input)
        let old = await next.next()
        let oldFrame = try XCTUnwrap(old)
        drawer.finish(oldFrame)
        XCTAssertNil(layer.contents)
        let current = await next.next()
        drawer.finish(try XCTUnwrap(current))
        let surface = try XCTUnwrap(layer.contents as? IOSurface)
        surface.lock(options: .readOnly, seed: nil)
        XCTAssertEqual(surface.baseAddress.load(as: UInt32.self), 0xFF00_00FF)
        surface.unlock(options: .readOnly, seed: nil)
        drawer.remove(0)
        layer.contents = nil
        drawer.update(0, layer: layer, program: program, input: input)
        drawer.finish(oldFrame)
        XCTAssertNil(layer.contents)
        let replacement = await next.next()
        drawer.finish(try XCTUnwrap(replacement))
        XCTAssertNotNil(layer.contents)
        drawer.remove(0)
        frames.continuation.finish()
    }
}
