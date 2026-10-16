// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreVideo
import IOSurface
import Metal
import QuartzCore

final class ShellShaderDrawer {
    static let frameBudget: CFTimeInterval = 0.008
    static let overrunLimit = 3
    static let maximumPixels = 4096

    static let timeWrap: CFTimeInterval = 86400
    static let transitionRate = 60

    struct Frame: Sendable {
        let slot: Int32
        let token: Int
        let index: Int
        let program: ShellShaderProgram
        let revision: Int
        let failure: String?
        let duration: Double
    }

    typealias Completion = @Sendable (Frame) -> Void

    private final class Target {
        let layer: CALayer
        let token: Int
        let start = CACurrentMediaTime()
        var program: ShellShaderProgram?
        var input: ShellShaderInput
        var image: CGImage?
        var source: (any MTLTexture)?
        var revision = 0
        var surfaces: [IOSurface] = []
        var textures: [any MTLTexture] = []
        var width = 0
        var height = 0
        var next = 0
        var inFlight = false
        var pending = false
        var lastDraw: CFTimeInterval = 0
        var overruns = 0
        var mask: ShellLayerMask?
        var displayed: Int?

        init(layer: CALayer, token: Int, input: ShellShaderInput) {
            self.layer = layer
            self.token = token
            self.input = input
        }
    }

    private let emptySource = ShellShaderTexture.make(nil)
    private let scale: CGFloat
    private let container: CALayer
    private let queue: DispatchSerialQueue
    private let completion: Completion
    private let bands: ShellSpectrumBands
    private var targets: [Int32: Target] = [:]
    private var tokens = 0
    private var visible = true
    private var transition = ShellShaderTransition.settled
    private var stage: ShellShaderStage?
    private var timer: (any DispatchSourceTimer)?
    private var timerRate = 0

    init(
        scale: CGFloat,
        container: CALayer,
        queue: DispatchSerialQueue,
        bands: ShellSpectrumBands = .live,
        completion: @escaping Completion
    ) {
        self.scale = scale
        self.container = container
        self.queue = queue
        self.bands = bands
        self.completion = completion
    }

    deinit {
        timer?.cancel()
    }

    func update(
        _ slot: Int32,
        layer: CALayer,
        program: ShellShaderProgram?,
        input: ShellShaderInput,
        mask: ShellLayerMask? = nil
    ) {
        let target: Target
        if let existing = targets[slot] {
            target = existing
        } else {
            tokens += 1
            target = Target(layer: layer, token: tokens, input: input)
            targets[slot] = target
        }
        if target.program !== program {
            target.overruns = 0
        }
        target.revision += 1
        if target.image !== input.image || target.source == nil {
            target.image = input.image
            target.source = input.image.flatMap { ShellShaderTexture.make($0) } ?? emptySource
        }
        target.program = program
        target.input = input
        target.mask = mask
        if program?.pipeline == nil, program?.isCompiling != true {
            clear(target)
        }
        draw(slot, target)
        updateTimer()
    }

    func alpha(_ slot: Int32, at point: CGPoint) -> Float? {
        guard let target = targets[slot], let index = target.displayed, index < target.surfaces.count else {
            return nil
        }
        let x = Int((point.x * scale).rounded(.down))
        let y = Int((point.y * scale).rounded(.down))
        guard x >= 0, y >= 0, x < target.width, y < target.height else { return 0 }
        let surface = target.surfaces[index]
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let alpha = surface.baseAddress.load(fromByteOffset: y * surface.bytesPerRow + x * 4 + 3, as: UInt8.self)
        return Float(alpha) / 255
    }

    func setMask(_ slot: Int32, _ mask: ShellLayerMask?) {
        guard let target = targets[slot] else { return }
        target.mask = mask
        if let mask, target.program?.pipeline == nil, target.program?.isCompiling != true {
            Self.unmask(mask)
        }
    }

    func resize(_ slot: Int32) {
        guard let target = targets[slot] else { return }
        let (width, height) = pixels(of: target.layer)
        guard width != target.width || height != target.height else { return }
        draw(slot, target)
    }

    func remove(_ slot: Int32) {
        guard targets.removeValue(forKey: slot) != nil else { return }
        updateTimer()
    }

    func setTransition(_ next: ShellShaderTransition) {
        guard transition != next else { return }
        transition = next
        redrawAll()
        updateTimer()
    }

    func setStage(_ next: ShellShaderStage?) {
        guard stage != next else { return }
        stage = next
        redrawAll()
    }

    private func redrawAll() {
        for (slot, target) in targets {
            draw(slot, target)
        }
    }

    func setVisible(_ isVisible: Bool) {
        guard visible != isVisible else { return }
        visible = isVisible
        if isVisible {
            for (slot, target) in targets {
                draw(slot, target)
            }
        }
        updateTimer()
    }

    func finish(_ frame: Frame) {
        let program = frame.program
        let index = frame.index
        guard let target = targets[frame.slot], target.token == frame.token else { return }
        target.inFlight = false
        let current = target.program === program
        if handleFailure(frame, target: target, current: current) { return }
        guard acceptFrameBudget(frame, target: target, current: current) else { return }
        guard current, target.revision == frame.revision else {
            if target.pending { draw(frame.slot, target) }
            return
        }
        guard index < target.surfaces.count else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.layer.contents = target.surfaces[index]
        target.displayed = index
        if let mask = target.mask {
            mask.layer.contents = target.surfaces[index]
            if mask.host.mask !== mask.layer {
                mask.host.mask = mask.layer
            }
        }
        CATransaction.commit()
        target.next = 1 - index
        if target.pending {
            draw(frame.slot, target)
        }
    }

    private func handleFailure(_ frame: Frame, target: Target, current: Bool) -> Bool {
        let program = frame.program
        if let failure = frame.failure {
            program.fail(failure)
            if current {
                clear(target)
            } else if target.pending {
                draw(frame.slot, target)
            }
            return true
        }
        return false
    }

    private func acceptFrameBudget(_ frame: Frame, target: Target, current: Bool) -> Bool {
        let program = frame.program
        if current, frame.duration > Self.frameBudget {
            target.overruns += 1
            if target.overruns >= Self.overrunLimit {
                program.fail("took \(Int((frame.duration * 1000).rounded())) ms per frame, over the 8 ms budget")
                clear(target)
                return false
            }
        } else if current {
            target.overruns = 0
        }
        return true
    }

    private func clear(_ target: Target) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.layer.contents = nil
        target.displayed = nil
        if let mask = target.mask {
            Self.unmask(mask)
        }
        CATransaction.commit()
    }

    private static func unmask(_ mask: ShellLayerMask) {
        mask.layer.contents = nil
        if mask.host.mask === mask.layer {
            mask.host.mask = nil
        }
    }

    private func draw(_ slot: Int32, _ target: Target) {
        guard visible,
              let program = target.program,
              let pipeline = program.pipeline,
              let device = ShellShaderGPU.device,
              let queue = ShellShaderGPU.queue
        else {
            return
        }
        guard ready(target, device: device) else { return }
        let index = target.next
        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: Self.pass(into: target.textures[index]))
        else {
            return
        }
        let now = CACurrentMediaTime()
        var uniforms = target.input.uniforms(
            size: target.layer.bounds.size,
            scale: scale,
            elapsed: now - target.start,
            now: now,
            transition: transition,
            stage: stage(in: target.layer),
            audio: target.input.audio ? bands.current : .init(repeating: 0)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(target.source, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShellShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        target.inFlight = true
        target.pending = false
        target.lastDraw = now
        let completion = completion
        let token = target.token
        let revision = target.revision
        buffer.addCompletedHandler { buffer in
            let failure = buffer.status == .error ? buffer.error?
                .localizedDescription ?? "the GPU reported an error" : nil
            completion(Frame(
                slot: slot,
                token: token,
                index: index,
                program: program,
                revision: revision,
                failure: failure,
                duration: buffer.gpuEndTime - buffer.gpuStartTime
            ))
        }
        buffer.commit()
    }
}

extension ShellShaderDrawer {
    private func ready(_ target: Target, device: any MTLDevice) -> Bool {
        let (width, height) = pixels(of: target.layer)
        guard width > 0, height > 0, width <= Self.maximumPixels, height <= Self.maximumPixels else { return false }
        guard !target.inFlight else {
            target.pending = true
            return false
        }
        if width != target.width || height != target.height {
            return allocate(target, width: width, height: height, device: device)
        }
        return true
    }

    private static func pass(into texture: any MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    private func stage(in layer: CALayer) -> ShellShaderStage? {
        stage.map { stage in
            ShellShaderStage(
                anchor: layer.convert(stage.anchor, from: container),
                content: layer.convert(stage.content, from: container)
            )
        }
    }

    private func allocate(_ target: Target, width: Int, height: Int, device: any MTLDevice) -> Bool {
        var surfaces: [IOSurface] = []
        var textures: [any MTLTexture] = []
        for _ in 0 ..< 2 {
            guard let surface = IOSurface(properties: [
                .width: width,
                .height: height,
                .bytesPerElement: 4,
                .pixelFormat: kCVPixelFormatType_32BGRA
            ]) else {
                return false
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = .renderTarget
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
                return false
            }
            surfaces.append(surface)
            textures.append(texture)
        }
        target.surfaces = surfaces
        target.textures = textures
        target.displayed = nil
        target.width = width
        target.height = height
        target.next = 0
        return true
    }

    private func pixels(of layer: CALayer) -> (Int, Int) {
        (Int((layer.bounds.width * scale).rounded(.up)), Int((layer.bounds.height * scale).rounded(.up)))
    }

    private var shaderRate: Int {
        targets.values.lazy.filter { $0.program?.pipeline != nil }.map(\.input.rate).max() ?? 0
    }

    private func updateTimer() {
        let drawsTransition = transition.drivesFrames(at: CACurrentMediaTime())
            && targets.values.contains { $0.program?.pipeline != nil }
        let rate = visible ? max(shaderRate, drawsTransition ? Self.transitionRate : 0) : 0
        guard rate != timerRate else { return }
        timerRate = rate
        timer?.cancel()
        timer = nil
        guard rate > 0 else { return }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / rate), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        guard !transition.drivesFrames(at: now) else {
            redrawAll()
            return
        }
        if timerRate > shaderRate {
            redrawAll()
            updateTimer()
            return
        }
        for (slot, target) in targets where target.input.rate > 0 {
            guard now - target.lastDraw >= 1 / Double(target.input.rate) - 0.002 else { continue }
            draw(slot, target)
        }
    }
}

extension ShellShaderInput {
    func uniforms(
        size: CGSize,
        scale: CGFloat,
        elapsed: CFTimeInterval,
        now: CFTimeInterval,
        transition: ShellShaderTransition,
        stage: ShellShaderStage? = nil,
        audio: ShellSpectrumBands.Bars = .init(repeating: 0)
    ) -> ShellShaderUniforms {
        let animates = rate > 0
        let stage = stage ?? ShellShaderStage(
            anchor: CGPoint(x: size.width / 2, y: size.height / 2),
            content: CGRect(origin: .zero, size: size)
        )
        return ShellShaderUniforms(
            size: SIMD2(Float(size.width), Float(size.height)),
            scale: Float(scale),
            time: animates ? Float(elapsed.truncatingRemainder(dividingBy: ShellShaderDrawer.timeWrap)) : 0,
            values: values,
            colors: colors,
            progress: animates || transition.forced ? transition.progress(at: now) : transition.to,
            anchor: SIMD2(Float(stage.anchor.x), Float(stage.anchor.y)),
            content: SIMD4(
                Float(stage.content.minX),
                Float(stage.content.minY),
                Float(stage.content.width),
                Float(stage.content.height)
            ),
            audio: audio
        )
    }
}
