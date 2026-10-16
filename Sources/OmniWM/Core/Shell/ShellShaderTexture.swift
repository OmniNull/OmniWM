// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Metal

enum ShellShaderTexture {
    static func make(_ image: CGImage?) -> (any MTLTexture)? {
        guard let device = ShellShaderGPU.device else { return nil }
        let width = image?.width ?? 1
        let height = image?.height ?? 1
        guard width > 0, height > 0,
              width <= ShellImageFrames.pixelLimit, height <= ShellImageFrames.pixelLimit,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue
              ), let bytes = context.data
        else { return nil }
        if let image { context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: bytes, bytesPerRow: context.bytesPerRow
        )
        return texture
    }
}
