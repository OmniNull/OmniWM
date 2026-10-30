// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

enum ShellSettingsPreview {
    private static var sampleMonitor: Monitor {
        Monitor(
            id: .init(displayId: 0), displayId: 0,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876),
            hasNotch: false, name: "Sample display"
        )
    }

    enum Surface: Equatable, Sendable {
        case bar
        case island(expanded: Bool)
        case drawer(String)
    }

    struct Display: Equatable {
        let monitor: Monitor
        let resolved: ResolvedBarSettings
    }

    struct Request: Equatable {
        let config: ShellConfig
        let surface: Surface
        let style: ShellBarStyle
        let scale: CGFloat
        let dark: Bool
        let fullWidth: Bool
        let sourceGeneration: UInt64
        var display: Display?

        var barFullWidth: Bool {
            display?.resolved.fullWidth ?? fullWidth
        }
    }

    @MainActor
    static func style(settings: WorkspaceBarSettings, config: ShellConfig, monitor: Monitor? = nil) -> ShellBarStyle {
        let isolated = settings.isolated(profileOverride: config.barOverride)
        let previewMonitor = monitor ?? sampleMonitor
        let resolved = isolated.resolved(for: previewMonitor)
        let height = monitor.map {
            WorkspaceBarGeometry.resolve(monitor: $0, resolved: resolved, isVisible: true).barHeight
        } ?? CGFloat(resolved.height)
        let snapshot = WorkspaceBarSnapshot(
            projection: .init(items: [], scratchpads: []), backgroundOpacity: resolved.backgroundOpacity,
            barHeight: height
        )
        return ShellBarStyle(resolved, settings: isolated, snapshot: snapshot)
    }

    @MainActor
    static func display(settings: WorkspaceBarSettings, config: ShellConfig, monitor: Monitor) -> Display {
        Display(
            monitor: monitor,
            resolved: settings.isolated(profileOverride: config.barOverride).resolved(for: monitor)
        )
    }

    @MainActor
    static func cachedImage(
        for request: Request, slot: ShellSettingsPreviewCache.Slot? = nil
    ) async throws -> CGImage {
        try await ShellSettingsPreviewCache.shared.image(for: request, slot: slot)
    }

    @MainActor
    static func islandData(for request: Request, config: ShellIslandConfig) -> ShellIslandData {
        let monitor = request.display?.monitor ?? sampleMonitor
        let resolved = request.display?.resolved
            ?? WorkspaceBarSettings().isolated(profileOverride: request.config.barOverride).resolved(for: monitor)
        let reserved = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: resolved.enabled)
            .reservedInsets
        return ShellIslandData(
            monitor: monitor, geometry: ShellIslandGeometry(monitor: monitor, size: config.size(on: monitor)),
            visible: true, fullscreen: false, reservedInsets: reserved
        )
    }

    @MainActor
    static func render(_ request: Request) async throws -> CGImage {
        let config = request.config
        let names: [String]
        let islandSize: CGSize?
        let islandData: ShellIslandData?
        let expanded: Bool?
        switch request.surface {
        case .bar:
            names = config.leading + config.center + config.trailing
            islandSize = nil
            islandData = nil
            expanded = nil
        case let .island(value):
            guard let island = config.island else {
                throw ShellScriptFailure(kind: .runtime, message: "This style does not include an island.")
            }
            names = [island.root]
            if island.sizing == .display {
                let data = self.islandData(for: request, config: island)
                islandData = data
                islandSize = data.size
            } else {
                islandData = nil
                islandSize = island.size
            }
            expanded = value
        case let .drawer(id):
            return try await drawerImage(id, request: request)
        }
        var seen: Set<String> = []
        let components = islandSize == nil ? nil : config.island?.components
        let inputs = try names.filter { seen.insert($0).inserted }.map { name in
            guard let value = input(name, config: config, components: components) else {
                throw ShellScriptFailure(kind: .compile, message: "\(ShellBarLayout.title(of: name)) is not installed.")
            }
            return value
        }
        let trees = try await ShellSettingsPreviewRenderer.shared.render(
            inputs: inputs, values: ShellSettingsPreviewSamples.values(
                style: request.style, islandSize: islandSize, dark: request.dark, scale: request.scale,
                surface: islandData
            ), settings: config.widgetSettings, expanded: expanded
        )
        let images = try await ShellSettingsPreviewRaster.render(
            trees, theme: config.theme, dark: request.dark, scale: request.scale, limit: islandSize
        )
        try Task.checkCancellation()
        if let image = images.first, islandSize != nil { return image.image }
        return try await barImage(images, request: request)
    }

    static func input(
        _ name: String, config: ShellConfig, components: [ShellComponentInstance]? = nil
    ) -> ShellWidgetSourceLoader.Input? {
        guard let source = config.widget(name) ?? ShellConfig.bundledWidget(name) else { return nil }
        return ShellWidgetSourceLoader.Input(
            name: name, shellDirectory: config.directories.first ?? source.deletingLastPathComponent(),
            sourceURL: source, directories: config.directories, profile: config.profile, components: components
        )
    }
}
