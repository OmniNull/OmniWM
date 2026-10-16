// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

extension ShellSettingsPreview {
    @MainActor
    static func barImage(
        _ images: [ShellSettingsPreviewRaster.Image],
        request: Request
    ) async throws -> CGImage {
        guard !images.isEmpty else {
            throw ShellScriptFailure(kind: .runtime, message: "Add a widget to preview the bar.")
        }
        let vertical = request.style.vertical
        let sizes = images.map { vertical ? $0.size.height : $0.size.width }
        let natural = sizes.reduce(8, +) + CGFloat(max(0, images.count - 1)) * 8
        let length = request.fullWidth ? max(960, min(natural, 1800)) : min(natural, 1800)
        let thickness = max(
            CGFloat(request.style.height),
            images.map { vertical ? $0.size.width : $0.size.height }.max() ?? 0
        )
        let size = vertical ? CGSize(width: thickness, height: length) : CGSize(width: length, height: thickness)
        let scale = ShellSettingsPreviewResolution.scale(size: size, requested: request.scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: ShellSettingsPreviewResolution.width(size: size, scale: scale),
                  height: ShellSettingsPreviewResolution.height(size: size, scale: scale),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw ShellScriptFailure(kind: .memory, message: "The bar preview image could not be created.") }
        context.scaleBy(x: scale, y: scale)
        drawBackground(in: context, size: size, thickness: thickness, request: request)
        try await drawShader(in: context, size: size, scale: scale, request: request)
        let offsets = offsets(of: images, sizes: sizes, length: length, request: request)
        drawWidgets(images, in: context, size: size, offsets: offsets, vertical: vertical)
        guard let image = context.makeImage() else {
            throw ShellScriptFailure(kind: .memory, message: "The bar preview could not be rendered.")
        }
        return image
    }

    @MainActor
    private static func drawBackground(
        in context: CGContext, size: CGSize, thickness: CGFloat, request: Request
    ) {
        let backgroundStyle = WorkspaceBarSnapshot(
            projection: .init(items: [], scratchpads: []), backgroundOpacity: request.style.opacity,
            transparentBackground: request.style.transparent, solidBlackBackground: request.style.solidBlack,
            barHeight: thickness, barFill: request.config.barOverride?.barFill,
            barBorder: request.config.barOverride?.barBorder
        ).backgroundStyle
        let fill: NSColor? = switch backgroundStyle {
        case .transparent: nil
        case .solidBlack: .black
        case .material: (request.dark ? NSColor.white : .black).withAlphaComponent(
                CGFloat(request.style.opacity) * (request.dark ? 1 : 0.5)
            )
        case let .palette(color, _): color.color(dark: request.dark).withAlphaComponent(CGFloat(request.style.opacity))
        }
        if let fill {
            context.setFillColor(fill.cgColor)
            let radius: CGFloat = request.fullWidth || request.style.solidBlack ? 0 : WorkspaceBarGeometry.cornerRadius
            context.addPath(CGPath(
                roundedRect: CGRect(origin: .zero, size: size),
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            ))
            context.fillPath()
        }
    }

    @MainActor
    private static func drawShader(in context: CGContext, size: CGSize, scale: CGFloat, request: Request) async throws {
        if let shader = request.config.barShader {
            let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
            resources.palette.refresh(
                theme: request.config.theme,
                appearance: NSAppearance(named: request.dark ? .darkAqua : .aqua) ?? NSApplication.shared
                    .effectiveAppearance
            )
            let program = resources.shaders.program(source: shader.source, directories: request.config.directories.map {
                $0.appendingPathComponent("shaders", isDirectory: true)
            })
            await ShellSettingsPreviewRaster.wait(for: [program], in: resources.shaders)
            guard let pipeline = program.pipeline else {
                throw ShellScriptFailure(kind: .runtime, message: program.failure ?? "The bar shader is unavailable.")
            }
            let background = try await ShellSettingsPreviewShader.shared.render(
                pipeline: pipeline, input: .init(
                    values: shader.values,
                    rate: 0,
                    colors: resources.palette.shaderColors
                ),
                size: size, scale: scale
            )
            context.draw(background, in: CGRect(origin: .zero, size: size))
        }
    }

    private static func offsets(
        of images: [ShellSettingsPreviewRaster.Image], sizes: [CGFloat], length: CGFloat, request: Request
    ) -> [CGFloat] {
        let vertical = request.style.vertical
        let offsets: [CGFloat]
        if request.fullWidth {
            offsets = WorkspaceBarZoneLayout.offsets(
                of: images.map { (request.config.lane(of: $0.name).lane, vertical ? $0.size.height : $0.size.width) },
                length: length, zones: .init(notch: nil, mode: .moveBelowMenuBar), spacing: 8, inset: 4
            )
        } else {
            var cursor: CGFloat = 4
            offsets = sizes.map { extent in
                defer { cursor += extent + 8 }
                return cursor
            }
        }
        return offsets
    }

    private static func drawWidgets(
        _ images: [ShellSettingsPreviewRaster.Image], in context: CGContext,
        size: CGSize, offsets: [CGFloat], vertical: Bool
    ) {
        for (index, image) in images.enumerated() {
            context.draw(
                image.image,
                in: vertical
                    ? CGRect(
                        x: (size.width - image.size.width) / 2,
                        y: size.height - offsets[index] - image.size.height,
                        width: image.size.width,
                        height: image.size.height
                    )
                    : CGRect(
                        x: offsets[index],
                        y: (size.height - image.size.height) / 2,
                        width: image.size.width,
                        height: image.size.height
                    )
            )
        }
    }
}
