// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct ShellSettingsPreview: View {
    enum Surface: Equatable, Sendable {
        case bar
        case island(expanded: Bool)
    }

    struct Request: Equatable {
        let config: ShellConfig
        let surface: Surface
        let style: ShellBarStyle
        let scale: CGFloat
        let dark: Bool
        let fullWidth: Bool
        let revision: UInt64
    }

    let config: ShellConfig
    var surface = Surface.bar
    var style = ShellBarStyle()
    var fullWidth: Bool?
    var revision: UInt64 = 0
    var onRendered: ((CGImage) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var failure: String?

    private var request: Request {
        Request(
            config: config,
            surface: surface,
            style: style,
            scale: displayScale,
            dark: colorScheme == .dark,
            fullWidth: fullWidth ?? config.barOverride?.settings.fullWidth ?? false,
            revision: revision
        )
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else if let failure {
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failure)
                )
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .task(id: request) {
            let value = request
            image = nil
            failure = nil
            do {
                let rendered = try await ShellSettingsPreviewCache.shared.image(for: value)
                try Task.checkCancellation()
                image = rendered
                onRendered?(rendered)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                failure = (error as? ShellScriptFailure)?.message ?? error.localizedDescription
            }
        }
    }

    @MainActor
    static func style(settings: WorkspaceBarSettings, config: ShellConfig, monitor: Monitor? = nil) -> ShellBarStyle {
        let isolated = WorkspaceBarSettings()
        let values = settings.export()
        isolated.applyIdentity(values)
        isolated.applyAppearance(values, monitorOverrides: settings.monitorOverrides)
        isolated.profileOverride = config.barOverride
        let monitor = monitor ?? Monitor(
            id: .init(displayId: 0),
            displayId: 0,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876),
            hasNotch: false,
            name: "Sample display"
        )
        let resolved = isolated.resolved(for: monitor)
        let snapshot = WorkspaceBarSnapshot(
            projection: .init(items: [], scratchpads: []), backgroundOpacity: resolved.backgroundOpacity,
            barHeight: resolved.height
        )
        return ShellBarStyle(resolved, settings: isolated, snapshot: snapshot)
    }

    @MainActor
    static func cachedImage(for request: Request) async throws -> CGImage {
        try await ShellSettingsPreviewCache.shared.image(for: request)
    }

    @MainActor
    static func render(_ request: Request) async throws -> CGImage {
        let config = request.config
        let names: [String]
        let islandSize: CGSize?
        let expanded: Bool?
        switch request.surface {
        case .bar:
            names = config.leading + config.center + config.trailing
            islandSize = nil
            expanded = nil
        case let .island(value):
            guard let island = config.island else {
                throw ShellScriptFailure(kind: .runtime, message: "This style does not include an island.")
            }
            names = [island.root]
            islandSize = island.size
            expanded = value
        }
        var seen: Set<String> = []
        let inputs = try names.filter { seen.insert($0).inserted }.map { name in
            guard let source = config.widget(name) ?? ShellConfig.bundledWidget(name) else {
                throw ShellScriptFailure(kind: .compile, message: "\(ShellBarLayout.title(of: name)) is not installed.")
            }
            return ShellWidgetSourceLoader.Input(
                name: name, shellDirectory: config.directories.first ?? source.deletingLastPathComponent(),
                sourceURL: source, directories: config.directories, profile: config.profile,
                components: islandSize == nil ? nil : config.island?.components
            )
        }
        let trees = try await ShellSettingsPreviewRenderer.shared.render(
            inputs: inputs, values: ShellSettingsPreviewSamples.values(
                style: request.style, islandSize: islandSize, dark: request.dark, scale: request.scale
            ), settings: config.widgetSettings, expanded: expanded
        )
        let images = try await ShellSettingsPreviewRaster.render(
            trees, theme: config.theme, dark: request.dark, scale: request.scale, limit: islandSize
        )
        try Task.checkCancellation()
        if let image = images.first, islandSize != nil { return image.image }
        return try await barImage(images, request: request)
    }
}

@MainActor
final class ShellSettingsPreviewCache {
    private struct Pending {
        let id: UUID
        let request: ShellSettingsPreview.Request
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<CGImage, any Error>]
    }

    static let shared = ShellSettingsPreviewCache()
    static let maximumBytes = 32 << 20
    private let render: @MainActor (ShellSettingsPreview.Request) async throws -> CGImage
    private var entries: [(ShellSettingsPreview.Request, CGImage)] = []
    private var pending: [Pending] = []
    private(set) var retainedBytes = 0
    var count: Int {
        entries.count
    }

    init(render: @escaping @MainActor (ShellSettingsPreview.Request) async throws -> CGImage = ShellSettingsPreview
        .render)
    {
        self.render = render
    }

    func image(for request: ShellSettingsPreview.Request) async throws -> CGImage {
        try Task.checkCancellation()
        if let index = entries.firstIndex(where: { $0.0 == request }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.1
        }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                CGImage,
                any Error
            >) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let index = pending.firstIndex(where: { $0.request == request }) {
                    pending[index].waiters[waiter] = continuation
                    return
                }
                let id = UUID()
                let task = Task { [weak self, render] in
                    let result: Result<CGImage, any Error>
                    do {
                        let image = try await render(request)
                        try Task.checkCancellation()
                        result = .success(image)
                    } catch {
                        result = .failure(error)
                    }
                    self?.complete(id, result: result)
                }
                pending.append(Pending(id: id, request: request, task: task, waiters: [waiter: continuation]))
            }
            try Task.checkCancellation()
            return image
        } onCancel: {
            Task { @MainActor in self.cancel(waiter) }
        }
    }

    private func cancel(_ waiter: UUID) {
        guard let index = pending.firstIndex(where: { $0.waiters[waiter] != nil }),
              let continuation = pending[index].waiters.removeValue(forKey: waiter)
        else { return }
        if pending[index].waiters.isEmpty {
            pending.remove(at: index).task.cancel()
        }
        continuation.resume(throwing: CancellationError())
    }

    private func complete(_ id: UUID, result: Result<CGImage, any Error>) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let entry = pending.remove(at: index)
        if case let .success(image) = result { insert(image, for: entry.request) }
        for continuation in entry.waiters.values { continuation.resume(with: result) }
    }

    func insert(_ image: CGImage, for request: ShellSettingsPreview.Request) {
        if let index = entries.firstIndex(where: { $0.0 == request }) {
            let removed = entries.remove(at: index).1
            retainedBytes -= removed.bytesPerRow * removed.height
        }
        entries.append((request, image))
        retainedBytes += image.bytesPerRow * image.height
        while entries.count > 12 || retainedBytes > Self.maximumBytes {
            let removed = entries.removeFirst().1
            retainedBytes -= removed.bytesPerRow * removed.height
        }
    }
}
