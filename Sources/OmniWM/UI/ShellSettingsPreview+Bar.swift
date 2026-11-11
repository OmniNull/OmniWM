// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
        let geometry = geometry(of: images, natural: natural, request: request)
        let length = geometry.length
        let thickness = geometry.thickness
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
        drawOutline(in: context, size: size, thickness: thickness, request: request)
        let spans = spans(of: images, sizes: sizes, length: length, zones: geometry.zones, request: request)
        drawWidgets(images, in: context, size: size, spans: spans, request: request)
        guard let image = context.makeImage() else {
            throw ShellScriptFailure(kind: .memory, message: "The bar preview could not be rendered.")
        }
        return image
    }

    @MainActor
    private static func backgroundStyle(thickness: CGFloat, request: Request) -> WorkspaceBarSnapshot.BackgroundStyle {
        WorkspaceBarSnapshot(
            projection: .init(items: [], scratchpads: []), backgroundOpacity: request.style.opacity,
            transparentBackground: request.style.transparent, solidBlackBackground: request.style.solidBlack,
            barHeight: thickness, barFill: request.config.barOverride?.barFill,
            barBorder: request.config.barOverride?.barBorder
        ).backgroundStyle
    }

    private static func cornerRadius(request: Request) -> CGFloat {
        request.barFullWidth || request.style.solidBlack ? 0 : WorkspaceBarGeometry.cornerRadius
    }

    private struct BarGeometry {
        let length: CGFloat
        let thickness: CGFloat
        let zones: WorkspaceBarZones?
    }

    @MainActor
    private static func geometry(
        of images: [ShellSettingsPreviewRaster.Image], natural: CGFloat, request: Request
    ) -> BarGeometry {
        let vertical = request.style.vertical
        let content = images.map { vertical ? $0.size.width : $0.size.height }.max() ?? 0
        guard let display = request.display else {
            return BarGeometry(
                length: request.fullWidth ? max(960, min(natural, 1800)) : min(natural, 1800),
                thickness: max(CGFloat(request.style.height), content),
                zones: request.fullWidth ? .init(notch: nil, mode: .moveBelowMenuBar) : nil
            )
        }
        let bar = WorkspaceBarGeometry.resolve(monitor: display.monitor, resolved: display.resolved, isVisible: true)
        let frame = bar.frame(fittingLength: natural, monitor: display.monitor, resolved: display.resolved)
        return BarGeometry(
            length: vertical ? frame.height : frame.width,
            thickness: max(bar.barHeight, content),
            zones: bar.zones(frame: frame, monitor: display.monitor, resolved: display.resolved)
        )
    }

    @MainActor
    private static func drawBackground(
        in context: CGContext, size: CGSize, thickness: CGFloat, request: Request
    ) {
        let backgroundStyle = backgroundStyle(thickness: thickness, request: request)
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
            let radius = cornerRadius(request: request)
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
    private static func drawOutline(in context: CGContext, size: CGSize, thickness: CGFloat, request: Request) {
        let style = backgroundStyle(thickness: thickness, request: request)
        guard !request.barFullWidth || style != .material,
              let outline = style.outline(
                  contrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .increased : .standard,
                  colorScheme: request.dark ? .dark : .light
              ),
              let appearance = NSAppearance(named: request.dark ? .darkAqua : .aqua)
        else { return }
        var color: CGColor?
        appearance.performAsCurrentDrawingAppearance { color = NSColor(outline.color).cgColor }
        guard let color else { return }
        let inset = outline.width / 2
        let radius = max(0, cornerRadius(request: request) - inset)
        context.setStrokeColor(color)
        context.setLineWidth(outline.width)
        context.addPath(CGPath(
            roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset),
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.strokePath()
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

    private static func spans(
        of images: [ShellSettingsPreviewRaster.Image], sizes: [CGFloat], length: CGFloat,
        zones: WorkspaceBarZones?, request: Request
    ) -> [WorkspaceBarZoneLayout.Span] {
        guard let zones else {
            var cursor: CGFloat = 4
            return sizes.map { extent in
                defer { cursor += extent + 8 }
                return WorkspaceBarZoneLayout.Span(start: cursor, length: extent)
            }
        }
        let priorities = request.config.priorityRanks()
        return WorkspaceBarZoneLayout.spans(
            of: zip(images, sizes).map { image, extent in
                WorkspaceBarZoneLayout.Item(
                    lane: request.config.lane(of: image.name).lane,
                    length: extent,
                    priority: priorities[image.name] ?? .max
                )
            },
            length: length, zones: zones, spacing: 8, inset: 4
        )
    }

    private static func drawWidgets(
        _ images: [ShellSettingsPreviewRaster.Image], in context: CGContext,
        size: CGSize, spans: [WorkspaceBarZoneLayout.Span], request: Request
    ) {
        let vertical = request.style.vertical
        for (index, image) in images.enumerated() where spans[index].length > 0 {
            let span = spans[index]
            let natural = vertical ? image.size.height : image.size.width
            let start = request.config.lane(of: image.name).lane == .trailing
                ? span.start + span.length - natural
                : span.start
            context.saveGState()
            if vertical {
                context.clip(to: CGRect(
                    x: 0,
                    y: size.height - span.start - span.length,
                    width: size.width,
                    height: span.length
                ))
                context.draw(image.image, in: CGRect(
                    x: (size.width - image.size.width) / 2,
                    y: size.height - start - image.size.height,
                    width: image.size.width,
                    height: image.size.height
                ))
            } else {
                context.clip(to: CGRect(x: span.start, y: 0, width: span.length, height: size.height))
                context.draw(image.image, in: CGRect(
                    x: start,
                    y: (size.height - image.size.height) / 2,
                    width: image.size.width,
                    height: image.size.height
                ))
            }
            context.restoreGState()
        }
    }
}
