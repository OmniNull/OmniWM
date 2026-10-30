// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import Metal
import QuartzCore

final class ShellLayerRaster {
    private let root: CALayer
    private let queue: any MTLCommandQueue
    private let texture: any MTLTexture
    private let renderer: CARenderer
    private let space: CGColorSpace
    private let width: Int
    private let height: Int
    private var marker: (any MTLCommandBuffer)?

    init(root: CALayer, width: Int, height: Int) throws {
        guard width > 0, height > 0,
              width <= ShellShaderDrawer.maximumPixels, height <= ShellShaderDrawer.maximumPixels
        else {
            throw ShellScriptFailure(
                kind: .runtime,
                message: "The layer raster dimensions exceed the 4096 pixel limit."
            )
        }
        guard let device = ShellShaderGPU.device, let queue = device.makeCommandQueue(),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw ShellScriptFailure(kind: .runtime, message: "Metal could not render this layer preview.") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ShellScriptFailure(kind: .memory, message: "The layer preview texture could not be created.")
        }
        let renderer = CARenderer(mtlTexture: texture, options: [
            kCARendererMetalCommandQueue: queue,
            kCARendererColorSpace: space
        ])
        renderer.layer = root
        renderer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        self.root = root
        self.queue = queue
        self.texture = texture
        self.renderer = renderer
        self.space = space
        self.width = width
        self.height = height
    }

    func encode(paused time: CFTimeInterval? = nil) throws -> any MTLCommandBuffer {
        guard marker == nil || marker?.status == .completed || marker?.status == .error else {
            throw ShellScriptFailure(kind: .runtime, message: "The previous layer preview render is still in flight.")
        }
        guard time?.isFinite != false else {
            throw ShellScriptFailure(kind: .runtime, message: "The layer preview animation time is invalid.")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let clear = queue.makeCommandBuffer(), let marker = queue.makeCommandBuffer(),
              let encoder = clear.makeRenderCommandEncoder(descriptor: pass)
        else { throw ShellScriptFailure(kind: .runtime, message: "The layer preview render could not be encoded.") }
        encoder.endEncoding()
        clear.commit()
        if let time {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.speed = 0
            root.timeOffset = time
            CATransaction.commit()
        }
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        self.marker = marker
        return marker
    }

    func pixels() -> [UInt8] {
        precondition(marker?.status == .completed)
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(
            &bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
        )
        for row in 0 ..< height / 2 {
            let opposite = height - row - 1
            for offset in 0 ..< bytesPerRow {
                bytes.swapAt(row * bytesPerRow + offset, opposite * bytesPerRow + offset)
            }
        }
        return bytes
    }

    func image() throws -> CGImage {
        guard marker?.status == .completed else {
            throw ShellScriptFailure(kind: .runtime, message: "The layer preview GPU render has not completed.")
        }
        guard let provider = CGDataProvider(data: Data(pixels()) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGBitmapInfo.byteOrder32Little
                      .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              )
        else { throw ShellScriptFailure(kind: .memory, message: "The layer preview image could not be created.") }
        return image
    }
}
