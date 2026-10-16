// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Metal
import OmniWMShellCore
import QuartzCore

enum ShellSettingsPreviewResolution {
    static let maximumDimension = 4096
    static let maximumPixels = 4_194_304

    static func scale(size: CGSize, requested: CGFloat) -> CGFloat {
        min(
            requested,
            CGFloat(maximumDimension) / max(size.width, size.height),
            sqrt(CGFloat(maximumPixels) / (size.width * size.height))
        )
    }

    static func width(size: CGSize, scale: CGFloat) -> Int {
        max(1, Int(floor(size.width * scale)))
    }

    static func height(size: CGSize, scale: CGFloat) -> Int {
        max(1, Int(floor(size.height * scale)))
    }
}

actor ShellSettingsPreviewShader {
    static let shared = ShellSettingsPreviewShader()

    func render(
        pipeline: any MTLRenderPipelineState,
        input: ShellShaderInput,
        size: CGSize,
        scale: CGFloat
    ) async throws -> CGImage {
        try Task.checkCancellation()
        let scale = ShellSettingsPreviewResolution.scale(size: size, requested: scale)
        let width = ShellSettingsPreviewResolution.width(size: size, scale: scale)
        let height = ShellSettingsPreviewResolution.height(size: size, scale: scale)
        guard width > 0, height > 0, max(width, height) <= ShellShaderDrawer.maximumPixels,
              let device = ShellShaderGPU.device, let queue = ShellShaderGPU.queue,
              let source = ShellShaderTexture.make(input.image), let buffer = queue.makeCommandBuffer()
        else { throw ShellScriptFailure(kind: .runtime, message: "Metal could not render this preview.") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ShellScriptFailure(kind: .memory, message: "The preview shader texture could not be created.")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw ShellScriptFailure(kind: .runtime, message: "The preview shader could not be encoded.")
        }
        var uniforms = input.uniforms(size: size, scale: scale, elapsed: 0, now: 0, transition: .settled)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShellShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            buffer.addCompletedHandler { completed in
                if completed.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ShellScriptFailure(
                        kind: .runtime,
                        message: completed.error?.localizedDescription ?? "The preview GPU render failed."
                    ))
                }
            }
            buffer.commit()
        }
        try Task.checkCancellation()
        return try image(from: texture, width: width, height: height)
    }

    private func image(from texture: any MTLTexture, width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                      .union(.byteOrder32Little), provider: provider, decode: nil, shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { throw ShellScriptFailure(kind: .memory, message: "The preview shader image could not be created.") }
        return image
    }
}

@MainActor
enum ShellSettingsPreviewRaster {
    struct Image {
        let name: String
        let image: CGImage
        let size: CGSize
    }

    static func render(
        _ trees: [ShellSettingsPreviewRenderer.Tree], theme: ShellTheme,
        dark: Bool, scale: CGFloat, limit: CGSize?
    ) async throws -> [Image] {
        let scale = limit.map { ShellSettingsPreviewResolution.scale(size: $0, requested: scale) } ?? scale
        let resources = ShellResources(
            motion: MotionPolicy(animationsEnabled: false),
            windowIcon: icon,
            iconOverride: icon
        )
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSApplication.shared.effectiveAppearance
        resources.palette.refresh(theme: theme, appearance: appearance)
        var images: [Image] = []
        for tree in trees {
            try Task.checkCancellation()
            let text = ShellTextStore()
            text.ingest(tree.strings, count: tree.stringCount)
            let surface = ShellWidgetSurface(scale: scale, resources: resources, directories: tree.directories)
            surface.drawsRootMaterial = true
            surface.assetFolders = tree.packages
            surface.text = text
            if let limit { surface.layout.setRootLimit(Size2(width: Float(limit.width), height: Float(limit.height))) }
            guard surface.layout.apply(tree.wire, text: text) else {
                throw ShellScriptFailure(kind: .runtime, message: "\(tree.name) has no renderable preview.")
            }
            var commands = surface.commands(text: text)
            let programs = surface.shaders.values.map(\.program)
            await wait(for: programs, in: resources.shaders)
            try Task.checkCancellation()
            try await rasterizeShaders(in: &commands, surface: surface, scale: scale)
            surface.scene.submit(commands, animated: false)
            let size = surface.size
            if size.width <= 0 || size.height <= 0 { continue }
            images.append(Image(
                name: tree.name,
                image: try await raster(surface.scene, size: size, scale: scale),
                size: size
            ))
        }
        return images
    }

    private static func icon(_ reference: String) -> NSImage? {
        let path = switch reference {
        case "com.apple.Safari",
             "sample-safari": "/Applications/Safari.app"
        case "com.apple.Notes",
             "sample-notes": "/System/Applications/Notes.app"
        case "com.apple.Terminal",
             "sample-terminal": "/System/Applications/Utilities/Terminal.app"
        case "com.apple.Music": "/System/Applications/Music.app"
        default: "/System/Library/CoreServices/Finder.app"
        }
        return NSWorkspace.shared.icon(forFile: path)
    }

    private static func rasterizeShaders(
        in commands: inout [ShellLayerCommand], surface: ShellWidgetSurface, scale: CGFloat
    ) async throws {
        for index in commands.indices {
            guard case let .shader(slot, program?, input) = commands[index],
                  let binding = surface.shaders[slot]
            else { continue }
            guard let pipeline = program.pipeline else {
                throw ShellScriptFailure(
                    kind: .runtime,
                    message: program.failure ?? "The preview shader is unavailable."
                )
            }
            let frame = CGRect(surface.layout.core.absoluteFrame(of: binding.handle))
            guard frame.width > 0, frame.height > 0 else {
                commands[index] = .image(slot: slot, image: nil, animation: nil)
                continue
            }
            let image = try await ShellSettingsPreviewShader.shared.render(
                pipeline: pipeline, input: input, size: frame.size, scale: scale
            )
            commands[index] = .image(slot: slot, image: image, animation: nil)
        }
    }

    static func wait(for programs: [ShellShaderProgram], in library: ShellShaderLibrary) async {
        guard programs.contains(where: \.isCompiling) else { return }
        await withCheckedContinuation { continuation in
            var resumed = false
            let completed: @MainActor () -> Void = {
                guard !resumed, !programs.contains(where: \.isCompiling) else { return }
                resumed = true
                continuation.resume()
            }
            library.onChange = completed
            library.onAssetChange = { _ in completed() }
        }
        library.onChange = nil
        library.onAssetChange = nil
    }

    static func raster(_ scene: ShellLayerScene, size: CGSize, scale: CGFloat) async throws -> CGImage {
        let scale = ShellSettingsPreviewResolution.scale(size: size, requested: scale)
        return try await withCheckedThrowingContinuation { continuation in
            ShellLayerScene.engineQueue.async {
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(
                          data: nil, width: ShellSettingsPreviewResolution.width(size: size, scale: scale),
                          height: ShellSettingsPreviewResolution.height(size: size, scale: scale),
                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      )
                else {
                    continuation.resume(throwing: ShellScriptFailure(
                        kind: .memory,
                        message: "The preview image could not be created."
                    ))
                    return
                }
                context.translateBy(x: 0, y: CGFloat(context.height))
                context.scaleBy(x: scale, y: -scale)
                scene.container.render(in: context)
                if let image = context.makeImage() {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: ShellScriptFailure(
                        kind: .memory,
                        message: "The preview image could not be rendered."
                    ))
                }
            }
        }
    }
}
