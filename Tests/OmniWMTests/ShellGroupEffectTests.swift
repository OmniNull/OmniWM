// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import IOSurface
import Metal
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
final class ShellGroupEffectTests: XCTestCase {
    private func program() throws -> ShellShaderProgram {
        guard ShellShaderGPU.device != nil else { throw XCTSkip("Metal is not available") }
        let pipeline = try ShellShaderLibrary.pipeline(Data("""
        #define OMNI_TEXTURE
        float4 shade(float2 uv, constant OmniShader& shader, texture2d<float> image) {
            return omni_sample(image, uv + float2(shader.values.x, 0));
        }
        """.utf8), name: "group-test")
        let program = ShellShaderProgram(name: "group-test")
        program.finish(pipeline, failure: nil)
        return program
    }

    private func input(
        _ program: ShellShaderProgram,
        x: Float = 0,
        bleed: CGFloat = 0,
        rate: Int = 0
    ) -> ShellGroupEffectInput {
        ShellGroupEffectInput(
            program: program,
            shader: ShellShaderInput(values: SIMD4(x, 0, 0, 0), rate: rate, colors: .init(repeating: .zero)),
            bleed: bleed, display: UInt32.max
        )
    }

    private func ordinaryPixels(_ container: CALayer, width: Int, height: Int) throws -> [UInt32] {
        let bytes = try ShellOffscreenRenderer(root: container, width: width, height: height).render()
        return stride(from: 0, to: bytes.count, by: 4).map {
            UInt32(bytes[$0]) | UInt32(bytes[$0 + 1]) << 8 | UInt32(bytes[$0 + 2]) << 16 | UInt32(bytes[$0 + 3]) << 24
        }
    }

    func testRetainedSourceUpdatesWithoutCaptureForOutputChangesAndClearsOldPixels() async throws {
        let program = try program()
        let container = CALayer()
        container.isGeometryFlipped = true
        let source = CALayer()
        source.anchorPoint = .zero
        source.bounds = CGRect(x: 0, y: 0, width: 24, height: 16)
        let square = CALayer()
        square.anchorPoint = .zero
        square.frame = CGRect(x: 2, y: 3, width: 4, height: 4)
        square.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        source.addSublayer(square)
        container.addSublayer(source)
        let group = ShellGroupEffect(source: source, scale: 1, input: input(program))
        group.attach()
        let frames = AsyncStream.makeStream(of: ShellShaderDrawer.Frame.self)
        var next = frames.stream.makeAsyncIterator()
        let drawer = ShellShaderDrawer(
            scale: 1, container: container, queue: ShellLayerScene.engineQueue
        ) { frames.continuation.yield($0) }
        drawer.updateGroup(0, group: group)
        drawer.redrawGroups()
        let first = await next.next()
        drawer.finish(try XCTUnwrap(first))
        XCTAssertEqual(group.renders, 1)
        XCTAssertTrue(source.superlayer !== container)
        XCTAssertTrue(container.sublayers?.first === group.output)
        XCTAssertTrue(source.sublayers?.first === square)
        let baseline = try XCTUnwrap(group.resources)
        var oldPixel: [UInt8] = [0, 0, 0, 0]
        baseline.mapped.getBytes(&oldPixel, bytesPerRow: 4, from: MTLRegionMake2D(3, 4, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(oldPixel, [0, 0, 255, 255])
        group.output.position = CGPoint(x: 100, y: 40)
        group.output.masksToBounds = true
        group.output.bounds.size = CGSize(width: 12, height: 8)
        drawer.redrawGroups()
        XCTAssertEqual(group.renders, 1)
        group.update(input(program, x: 0.1))
        drawer.updateGroup(0, group: group)
        drawer.redrawGroups()
        let warp = await next.next()
        drawer.finish(try XCTUnwrap(warp))
        XCTAssertEqual(group.renders, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        square.position.x = 12
        CATransaction.commit()
        group.invalidate()
        drawer.redrawGroups()
        let changed = await next.next()
        drawer.finish(try XCTUnwrap(changed))
        XCTAssertEqual(group.renders, 2)
        baseline.mapped.getBytes(&oldPixel, bytesPerRow: 4, from: MTLRegionMake2D(3, 4, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(oldPixel, [0, 0, 0, 0])
        group.restore()
        drawer.remove(0)
        XCTAssertTrue(source.superlayer === container)
        XCTAssertTrue(source.sublayers?.first === square)
        frames.continuation.finish()
    }

    func testOrientationNeutralOutputAndActualByteAdmission() async throws {
        let program = try program()
        let source = CALayer()
        source.anchorPoint = .zero
        source.bounds = CGRect(x: 0, y: 0, width: 8, height: 6)
        let stripe = CALayer()
        stripe.frame = CGRect(x: 0, y: 0, width: 8, height: 2)
        stripe.backgroundColor = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        source.addSublayer(stripe)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 2, width: 4, height: 2))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let image = CALayer()
        image.frame = CGRect(x: 4, y: 2, width: 4, height: 4)
        image.contents = context.makeImage()
        source.addSublayer(image)
        let container = CALayer()
        container.isGeometryFlipped = true
        container.anchorPoint = .zero
        container.bounds = CGRect(x: 0, y: 0, width: 8, height: 6)
        container.addSublayer(source)
        let ordinary = try ordinaryPixels(container, width: 8, height: 6)
        let group = ShellGroupEffect(source: source, scale: 1, input: input(program, x: 1))
        group.attach()
        group.setNeutral(true)
        let frames = AsyncStream.makeStream(of: ShellShaderDrawer.Frame.self)
        var next = frames.stream.makeAsyncIterator()
        let drawer = ShellShaderDrawer(
            scale: 1, container: container, queue: ShellLayerScene.engineQueue
        ) { frames.continuation.yield($0) }
        drawer.updateGroup(0, group: group)
        drawer.redrawGroups()
        let completed = await next.next()
        drawer.finish(try XCTUnwrap(completed))
        let resources = try XCTUnwrap(group.resources)
        let surface = try XCTUnwrap(group.output.contents as? IOSurface)
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        for y in 0 ..< 6 {
            for x in 0 ..< 8 {
                XCTAssertEqual(
                    surface.baseAddress.load(fromByteOffset: y * surface.bytesPerRow + x * 4, as: UInt32.self),
                    ordinary[y * 8 + x]
                )
            }
            XCTAssertEqual(
                surface.baseAddress.load(fromByteOffset: y * surface.bytesPerRow + 4, as: UInt32.self),
                y < 2 ? 0xFF00_FF00 : 0
            )
        }
        XCTAssertEqual(resources.lease.bytes, resources.backing.reduce(0) { $0 + $1.allocationSize })
        group.restore()
        drawer.remove(0)
        frames.continuation.finish()
    }

    func testNeutralStaticGroupStopsAuthoredFramesButKeepsTheSourceRate() async throws {
        let program = try program()
        let container = CALayer()
        container.isGeometryFlipped = true
        let source = CALayer()
        source.anchorPoint = .zero
        source.bounds = CGRect(x: 0, y: 0, width: 8, height: 6)
        source.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        container.addSublayer(source)
        let group = ShellGroupEffect(source: source, scale: 1, input: input(program, rate: 30))
        group.attach()
        group.setNeutral(true)
        let frames = AsyncStream.makeStream(of: ShellShaderDrawer.Frame.self)
        var next = frames.stream.makeAsyncIterator()
        let drawer = ShellShaderDrawer(
            scale: 1, container: container, queue: ShellLayerScene.engineQueue
        ) { frames.continuation.yield($0) }
        drawer.updateGroup(0, group: group)
        drawer.redrawGroups()
        XCTAssertEqual(drawer.timerRate, 0)
        let completed = await next.next()
        drawer.finish(try XCTUnwrap(completed))
        drawer.redrawGroups()
        XCTAssertEqual(drawer.timerRate, 0)
        XCTAssertEqual(group.renders, 1)
        let shader = group.input.shader
        XCTAssertEqual(ShellShaderDrawer.rate(input: shader, neutral: true, sourceRate: 60), 60)
        XCTAssertEqual(ShellShaderDrawer.rate(input: shader, neutral: true, sourceRate: 0), 0)
        group.restore()
        drawer.remove(0)
        frames.continuation.finish()
    }

    func testBudgetAndAxisRejectionLeaveTheOriginalContentVisible() throws {
        let program = try program()
        let container = CALayer()
        container.isGeometryFlipped = true
        let source = CALayer()
        source.bounds = CGRect(x: 0, y: 0, width: 4097, height: 1)
        container.addSublayer(source)
        let group = ShellGroupEffect(source: source, scale: 1, input: input(program))
        group.attach()
        XCTAssertFalse(group.prepare(at: CACurrentMediaTime()))
        XCTAssertTrue(source.superlayer === container)
        XCTAssertNil(group.output.superlayer)
        XCTAssertNil(ShellGroupEffectBudget.reserve(
            bytes: ShellGroupEffectBudget.displayLimit + 1,
            display: UInt32.max
        ))
        let display = UInt32.max - 1
        let reservation = try XCTUnwrap(ShellGroupEffectBudget.reserve(
            bytes: ShellGroupEffectBudget.displayLimit,
            display: display
        ))
        XCTAssertNil(ShellGroupEffectBudget.reserve(bytes: 1, display: display))
        let fitting = CALayer()
        fitting.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
        container.addSublayer(fitting)
        let exhausted = ShellGroupEffect(source: fitting, scale: 1, input: ShellGroupEffectInput(
            program: program, shader: input(program).shader, bleed: 0, display: display
        ))
        exhausted.attach()
        XCTAssertFalse(exhausted.prepare(at: CACurrentMediaTime()))
        XCTAssertEqual(exhausted.allocations, 0)
        XCTAssertTrue(fitting.superlayer === container)
        withExtendedLifetime(reservation) {}
    }

    func testExplicitEffectCommandRecoversAfterBoundsRejection() async throws {
        let program = try program()
        let binding = input(program)
        let container = CALayer()
        container.isGeometryFlipped = true
        let scene = ShellLayerScene(container: container, scale: 1)
        let applied = AsyncStream.makeStream(of: Void.self)
        var next = applied.stream.makeAsyncIterator()
        scene.submit([
            .insert(slot: 0, parent: -1, kind: .group, after: -1),
            .frame(slot: 0, rect: CGRect(x: 0, y: 0, width: 4097, height: 1), animation: nil),
            .effect(slot: 0, input: binding)
        ], animated: false) { applied.continuation.yield(()) }
        _ = await next.next()
        let rejected = ShellLayerScene.engineQueue.sync {
            (scene.effects[0]?.failed == true, scene.displayedLayer(0) === scene.layers[0])
        }
        XCTAssertTrue(rejected.0)
        XCTAssertTrue(rejected.1)
        scene.submit([
            .frame(slot: 0, rect: CGRect(x: 0, y: 0, width: 16, height: 16), animation: nil),
            .effect(slot: 0, input: binding)
        ], animated: false) { applied.continuation.yield(()) }
        _ = await next.next()
        let recovered = ShellLayerScene.engineQueue.sync {
            (
                scene.effects[0]?.failed == false,
                scene.effects[0]?.output.superlayer === container,
                scene.effects[0]?.resources != nil
            )
        }
        XCTAssertTrue(recovered.0)
        XCTAssertTrue(recovered.1)
        XCTAssertTrue(recovered.2)
        scene.submit([.remove(slot: 0)], animated: false) { applied.continuation.yield(()) }
        _ = await next.next()
        applied.continuation.finish()
    }

    func testScalarGestureAndSettlementInvalidateTheContainingSource() async throws {
        let program = try program()
        let container = CALayer()
        container.isGeometryFlipped = true
        let source = CALayer()
        source.anchorPoint = .zero
        source.bounds = CGRect(x: 0, y: 0, width: 24, height: 16)
        let square = CALayer()
        square.anchorPoint = .zero
        square.frame = CGRect(x: 2, y: 3, width: 4, height: 4)
        square.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        source.addSublayer(square)
        container.addSublayer(source)
        let group = ShellGroupEffect(source: source, scale: 1, input: input(program))
        group.attach()
        let frames = AsyncStream.makeStream(of: ShellShaderDrawer.Frame.self)
        var next = frames.stream.makeAsyncIterator()
        let drawer = ShellShaderDrawer(
            scale: 1, container: container, queue: ShellLayerScene.engineQueue
        ) { frames.continuation.yield($0) }
        drawer.updateGroup(0, group: group)
        drawer.redrawGroups()
        let initial = await next.next()
        drawer.finish(try XCTUnwrap(initial))
        XCTAssertEqual(group.renders, 1)
        let scene = ShellLayerScene(container: container, scale: 1)
        scene.layers = [0: source, 1: square]
        scene.parents = [1: 0]
        scene.effects = [0: group]
        scene.shaders = drawer
        scene.submit([
            .gesture(slot: 1, token: 1, value: ShellGestureTransform(dx: 4, dy: 0, scale: 1, opacity: 1))
        ], animated: false)
        let moved = await next.next()
        let movedFrame = try XCTUnwrap(moved)
        ShellLayerScene.engineQueue.sync { drawer.finish(movedFrame) }
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { group.renders }, 2)
        scene.submit([.settleGesture(slot: 1, token: 1, velocity: .zero, animation: nil)], animated: false)
        let settled = await next.next()
        let settledFrame = try XCTUnwrap(settled)
        ShellLayerScene.engineQueue.sync { drawer.finish(settledFrame) }
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { group.renders }, 3)
        scene.submit([.remove(slot: 0)], animated: false)
        ShellLayerScene.engineQueue.sync {}
        frames.continuation.finish()
    }
}
