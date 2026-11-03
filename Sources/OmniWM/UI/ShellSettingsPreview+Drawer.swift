// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellSettingsPreview {
    typealias Panel = ShellSettingsPreviewRenderer.Panel

    static let drawerHeight: CGFloat = 150

    struct PanelRequest: Equatable, Sendable {
        let profile: String
        let directories: [URL]
        let names: [String]
        let sources: [URL?]
        let sourceGeneration: UInt64

        init(names: [String], config: ShellConfig, sourceGeneration: UInt64) {
            profile = config.profile
            directories = config.directories
            self.names = names
            sources = names.map { config.widget($0) ?? ShellConfig.bundledWidget($0) }
            self.sourceGeneration = sourceGeneration
        }
    }

    @MainActor
    static func panels(for request: PanelRequest) async throws -> [String: Panel] {
        try await ShellSettingsPreviewCache.shared.panels(for: request)
    }

    static func probe(_ request: PanelRequest) async throws -> [String: Panel] {
        var panels: [String: Panel] = [:]
        var inputs: [ShellWidgetSourceLoader.Input] = []
        for (name, source) in zip(request.names, request.sources) {
            guard let source else {
                panels[name] = .failed(String(localized: "\(ShellBarLayout.title(of: name)) is not installed."))
                continue
            }
            inputs.append(ShellWidgetSourceLoader.Input(
                name: name, shellDirectory: request.directories.first ?? source.deletingLastPathComponent(),
                sourceURL: source, directories: request.directories, profile: request.profile
            ))
        }
        return try await panels.merging(ShellSettingsPreviewRenderer.shared.panels(inputs)) { $1 }
    }

    @MainActor
    static func drawerImage(_ id: String, request: Request, renderBudget: UInt64) async throws -> CGImage {
        let config = request.config
        guard let drawer = config.drawers.first(where: { $0.id == id }) else {
            throw ShellScriptFailure(kind: .runtime, message: String(localized: "This drawer no longer exists."))
        }
        var seen: Set<String> = []
        let inputs = drawer.widgets.filter { seen.insert($0).inserted }.compactMap { input($0, config: config) }
        let trees = try await ShellSettingsPreviewRenderer.shared.render(
            inputs: inputs, values: ShellSettingsPreviewSamples.values(
                style: request.style, islandSize: nil, dark: request.dark, scale: request.scale
            ), settings: config.widgetSettings, expanded: nil, popout: true, renderBudget: renderBudget
        )
        let padding = drawer.chrome ? ShellEdgeDrawer.padding : 0
        let images = try await ShellSettingsPreviewRaster.render(
            trees, theme: config.theme, dark: request.dark, scale: request.scale, limit: nil, rootMaterial: false
        ) { sizes in
            let height = sizes.map(\.height).reduce(padding * 2, +)
                + ShellEdgeDrawer.spacing * CGFloat(max(0, sizes.count - 1))
            return min(request.scale, request.scale * drawerHeight / max(height, 1))
        }
        try Task.checkCancellation()
        guard !images.isEmpty else {
            throw ShellScriptFailure(kind: .runtime, message: String(localized: "This drawer has nothing to show."))
        }
        return try compose(images, chrome: drawer.chrome, request: request)
    }

    @MainActor
    private static func compose(
        _ images: [ShellSettingsPreviewRaster.Image], chrome: Bool, request: Request
    ) throws -> CGImage {
        let padding = chrome ? ShellEdgeDrawer.padding : 0
        let content = images.map(\.size.width).max() ?? 0
        let height = images.map(\.size.height).reduce(0, +) + ShellEdgeDrawer.spacing * CGFloat(images.count - 1)
        let size = CGSize(width: content + padding * 2, height: height + padding * 2)
        let scale = ShellSettingsPreviewResolution.scale(size: size, requested: images.first?.scale ?? request.scale)
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
        else { throw ShellScriptFailure(kind: .memory, message: "The drawer preview image could not be created.") }
        context.scaleBy(x: scale, y: scale)
        if chrome, let appearance = NSAppearance(named: request.dark ? .darkAqua : .aqua) {
            var fill: CGColor?
            appearance.performAsCurrentDrawingAppearance { fill = NSColor.windowBackgroundColor.cgColor }
            if let fill {
                context.setFillColor(fill)
                context.addPath(CGPath(
                    roundedRect: CGRect(origin: .zero, size: size),
                    cornerWidth: ShellEdgeDrawer.radius,
                    cornerHeight: ShellEdgeDrawer.radius,
                    transform: nil
                ))
                context.fillPath()
            }
        }
        var top = size.height - padding
        for image in images {
            top -= image.size.height
            context.draw(image.image, in: CGRect(
                x: padding + (content - image.size.width) / 2, y: top,
                width: image.size.width, height: image.size.height
            ))
            top -= ShellEdgeDrawer.spacing
        }
        guard let image = context.makeImage() else {
            throw ShellScriptFailure(kind: .memory, message: "The drawer preview could not be rendered.")
        }
        return image
    }
}
