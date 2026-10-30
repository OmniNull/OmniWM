// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreVideo
import IOSurface
import Metal
import QuartzCore
import Synchronization

struct ShellGroupEffectInput: Sendable {
    let program: ShellShaderProgram
    let shader: ShellShaderInput
    let bleed: CGFloat
    let display: UInt32?
}

enum ShellGroupEffectBudget {
    static let displayLimit = 64 * 1024 * 1024
    static let processLimit = 128 * 1024 * 1024

    private struct State {
        var total = 0
        var displays: [UInt32: Int] = [:]
    }

    private static let state = Mutex(State())

    final class Lease: Sendable {
        let bytes: Int
        let display: UInt32

        fileprivate init(bytes: Int, display: UInt32) {
            self.bytes = bytes
            self.display = display
        }

        deinit {
            ShellGroupEffectBudget.state.withLock { value in
                value.total -= bytes
                let remaining = value.displays[display, default: 0] - bytes
                value.displays[display] = remaining > 0 ? remaining : nil
            }
        }
    }

    static func reserve(bytes: Int, display: UInt32?) -> Lease? {
        let key = display ?? 0
        return state.withLock { value in
            guard bytes > 0, bytes <= displayLimit,
                  value.total <= processLimit - bytes,
                  value.displays[key, default: 0] <= displayLimit - bytes else { return nil }
            value.total += bytes
            value.displays[key, default: 0] += bytes
            return Lease(bytes: bytes, display: key)
        }
    }
}

final class ShellGroupEffect {
    struct Resources {
        let source: any MTLTexture
        let mapped: any MTLTexture
        let backing: [IOSurface]
        let surfaces: [IOSurface]
        let outputs: [any MTLTexture]
        let lease: ShellGroupEffectBudget.Lease
    }

    private struct Programs: Sendable {
        let clear: any MTLRenderPipelineState
        let flip: any MTLRenderPipelineState
        let identity: any MTLRenderPipelineState
    }

    private static let programs: Programs? = {
        do {
            let clear = try ShellShaderLibrary.pipeline(Data("""
            float4 shade(float2 uv, constant OmniShader& shader) { return float4(0); }
            """.utf8), name: "group-clear")
            let flip = try ShellShaderLibrary.pipeline(Data("""
            #define OMNI_TEXTURE
            float4 shade(float2 uv, constant OmniShader& shader, texture2d<float> image) {
                return omni_sample(image, float2(uv.x, 1.0 - uv.y));
            }
            """.utf8), name: "group-orientation")
            let identity = try ShellShaderLibrary.pipeline(Data("""
            #define OMNI_TEXTURE
            float4 shade(float2 uv, constant OmniShader& shader, texture2d<float> image) {
                return omni_sample(image, uv);
            }
            """.utf8), name: "group-identity")
            return Programs(clear: clear, flip: flip, identity: identity)
        } catch {
            Log.shell.error("Group effect renderer: \(String(describing: error))")
            return nil
        }
    }()

    static let leaseKey = "omniwmGroupEffectLease"
    let source: CALayer
    let output = CALayer()
    private let root = CALayer()
    private let scaler = CALayer()
    let scale: CGFloat
    private(set) var input: ShellGroupEffectInput
    private(set) var resources: Resources?
    private var renderer: CARenderer?
    private var retired: [(Resources, CARenderer?)] = []
    private var inFlight = false
    private var sourceDirty = true
    private var firstFrame = true
    private(set) var nextFrame = CFTimeInterval.infinity
    private(set) var renders = 0
    private(set) var allocations = 0
    private(set) var sourceWall: CFTimeInterval = 0
    private(set) var sourceGPU: CFTimeInterval = 0
    private(set) var totalGPU: CFTimeInterval = 0
    private(set) var timing: ShellGroupEffectTiming?
    private(set) var neutral = false
    private(set) var failed = false

    init(source: CALayer, scale: CGFloat, input: ShellGroupEffectInput) {
        self.source = source
        self.scale = scale
        self.input = input
        for layer in [root, scaler, output] {
            layer.anchorPoint = .zero
            layer.contentsScale = scale
        }
        output.contentsGravity = .resize
        root.isGeometryFlipped = true
        root.addSublayer(scaler)
        synchronizeGeometry()
    }

    var sourceRate: Int {
        !failed && nextFrame.isFinite ? 60 : 0
    }

    var lease: ShellGroupEffectBudget.Lease? {
        resources?.lease
    }

    var identityPipeline: (any MTLRenderPipelineState)? {
        Self.programs?.identity
    }

    func update(_ next: ShellGroupEffectInput) {
        if input.bleed != next.bleed || input.display != next.display {
            retireResources()
            resources = nil
            renderer = nil
            firstFrame = true
            sourceDirty = true
        }
        input = next
        synchronizeGeometry()
    }

    func setNeutral(_ value: Bool) {
        neutral = value
    }

    func disable(_ message: String) {
        _ = fail(message)
    }

    func beginFrame() {
        inFlight = true
    }

    func finishFrame(sourceGPU: CFTimeInterval = 0, totalGPU: CFTimeInterval = 0) {
        inFlight = false
        self.sourceGPU = sourceGPU
        self.totalGPU = totalGPU
        retired.removeAll(keepingCapacity: true)
    }

    func invalidate() {
        sourceDirty = true
    }

    func needsSource(at now: CFTimeInterval) -> Bool {
        sourceDirty || now >= nextFrame
    }

    func attach() {
        guard let host = source.superlayer else { return }
        host.insertSublayer(output, above: source)
        source.removeFromSuperlayer()
        scaler.addSublayer(source)
    }

    func restore() {
        if let host = output.superlayer {
            host.insertSublayer(source, above: output)
            output.removeFromSuperlayer()
        }
        sourceDirty = true
        nextFrame = .infinity
        output.contents = nil
        output.setValue(nil, forKey: Self.leaseKey)
        retireResources()
        resources = nil
        renderer = nil
        timing = nil
    }

    private func retireResources() {
        if inFlight, let resources { retired.append((resources, renderer)) }
    }

    func synchronizeGeometry() {
        let bleed = max(input.bleed, 0)
        let size = CGSize(width: source.bounds.width + bleed * 2, height: source.bounds.height + bleed * 2)
        let origin = CGPoint(x: source.position.x - bleed, y: source.position.y - bleed)
        output.position = origin
        output.bounds = CGRect(origin: .zero, size: size)
        root.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        scaler.bounds = CGRect(origin: origin, size: size)
        scaler.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    private func fail(_ message: String) -> Bool {
        if !failed { Log.shell.error("Group effect \(input.program.name): \(message)") }
        failed = true
        nextFrame = .infinity
        restore()
        return false
    }
}

extension ShellGroupEffect {
    func prepare(at now: CFTimeInterval) -> Bool {
        guard !failed else { return false }
        guard let programs = Self.programs,
              let device = ShellShaderGPU.device,
              let queue = ShellShaderGPU.queue else { return fail("renderer unavailable") }
        synchronizeGeometry()
        let pixelWidth = (output.bounds.width * scale).rounded(.up)
        let pixelHeight = (output.bounds.height * scale).rounded(.up)
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= CGFloat(ShellShaderDrawer.maximumPixels),
              pixelHeight <= CGFloat(ShellShaderDrawer.maximumPixels)
        else { return fail("render bounds exceed the 4096 pixel limit") }
        let width = Int(pixelWidth)
        let height = Int(pixelHeight)
        if resources?.source.width != width || resources?.source.height != height {
            guard allocate(width: width, height: height, device: device, queue: queue) else { return false }
        }
        guard let renderer, let resources else { return false }
        timing = nil
        guard sourceDirty || now >= nextFrame else { return true }
        return renderSource(renderer, resources: resources, programs: programs, queue: queue, at: now)
    }

    private func renderSource(
        _ renderer: CARenderer, resources: Resources, programs: Programs,
        queue: any MTLCommandQueue, at now: CFTimeInterval
    ) -> Bool {
        CATransaction.flush()
        let started = CACurrentMediaTime()
        renderer.beginFrame(atTime: now, timeStamp: nil)
        if firstFrame { renderer.addUpdate(renderer.bounds) }
        let region = renderer.updateBounds().intersection(renderer.bounds)
        if !region.isEmpty {
            let timing = ShellGroupEffectTiming(lease: resources.lease)
            self.timing = timing
            guard let clear = clear(resources.source, region: region, pipeline: programs.clear, queue: queue) else {
                renderer.endFrame()
                return fail("source clear could not be encoded")
            }
            clear.addCompletedHandler { buffer in timing.record(buffer, start: true) }
            clear.commit()
            renderer.render()
            renders += 1
        }
        nextFrame = renderer.nextFrameTime()
        renderer.endFrame()
        sourceWall = CACurrentMediaTime() - started
        sourceDirty = false
        firstFrame = false
        return region.isEmpty || orientSource(resources, pipeline: programs.flip, queue: queue)
    }

    private func orientSource(
        _ resources: Resources,
        pipeline: any MTLRenderPipelineState,
        queue: any MTLCommandQueue
    ) -> Bool {
        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: Self.pass(resources.mapped, load: .clear))
        else { return fail("source orientation could not be encoded") }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(resources.source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        if let timing { buffer.addCompletedHandler { buffer in timing.record(buffer, start: false) } }
        buffer.commit()
        return true
    }

    private func allocate(width: Int, height: Int, device: any MTLDevice, queue: any MTLCommandQueue) -> Bool {
        guard width * height <= ShellGroupEffectBudget.displayLimit / 16 else { return fail("texture budget exceeded") }
        let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)
        let allocationSize = IOSurfaceAlignProperty(kIOSurfaceAllocSize, bytesPerRow * height)
        guard let lease = ShellGroupEffectBudget.reserve(bytes: allocationSize * 4, display: input.display) else {
            return fail("texture budget exceeded")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        var surfaces: [IOSurface] = []
        var textures: [any MTLTexture] = []
        for _ in 0 ..< 4 {
            allocations += 1
            guard let surface = IOSurface(properties: [
                .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA,
                .bytesPerRow: bytesPerRow, .allocSize: allocationSize
            ]), surface.allocationSize == allocationSize, surface.bytesPerRow == bytesPerRow,
            let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0),
            texture.allocatedSize <= allocationSize
            else { return fail("bounded texture allocation failed") }
            surfaces.append(surface)
            textures.append(texture)
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return fail("sRGB color space unavailable") }
        let source = textures[0]
        let renderer = CARenderer(mtlTexture: source, options: [
            kCARendererMetalCommandQueue: queue, kCARendererColorSpace: space
        ])
        renderer.layer = root
        renderer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        resources = Resources(
            source: source, mapped: textures[1], backing: surfaces,
            surfaces: Array(surfaces.suffix(2)), outputs: Array(textures.suffix(2)), lease: lease
        )
        self.renderer = renderer
        sourceDirty = true
        firstFrame = true
        return true
    }

    private func clear(
        _ texture: any MTLTexture, region: CGRect, pipeline: any MTLRenderPipelineState, queue: any MTLCommandQueue
    ) -> (any MTLCommandBuffer)? {
        let region = region.intersection(CGRect(x: 0, y: 0, width: texture.width, height: texture.height)).integral
        guard !region.isEmpty else { return nil }
        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: Self.pass(texture, load: .load))
        else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setScissorRect(MTLScissorRect(
            x: Int(region.minX), y: Int(region.minY), width: Int(region.width), height: Int(region.height)
        ))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return buffer
    }

    private static func pass(_ texture: any MTLTexture, load: MTLLoadAction) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        return pass
    }
}
