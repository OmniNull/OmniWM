// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct WallpaperPreviewKey: Hashable, Sendable {
    static let ratioScale = 1000.0

    let file: WallpaperFileStamp
    let width: Int
    let ratio: Int
    let placement: WallpaperPlacement

    init(file: WallpaperFileStamp, width: Int, display size: CGSize, placement: WallpaperPlacement) {
        self.file = file
        self.width = width
        let aspect = size.width > 0 && size.height > 0 ? size.width / size.height : WallpaperRendering.wideAspect
        ratio = Int((aspect * Self.ratioScale).rounded())
        self.placement = placement
    }

    var aspect: Double {
        Double(ratio) / Self.ratioScale
    }

    var id: String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in "\(file.path)|\(file.modified)|\(file.bytes)|\(width)|\(ratio)|\(placement.rawValue)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return WallpaperPreviews.prefix + String(hash, radix: 16)
    }
}

@MainActor
final class WallpaperPreviews {
    nonisolated static let prefix = "wallpaper/"
    nonisolated static let cardWidth = 800
    nonisolated static let gridWidth = 400
    nonisolated static let limit = 64
    nonisolated static let defaultWindow = 6
    nonisolated static let pageLimit = 24

    struct Window: Equatable, Sendable {
        var offset: Int
        var count: Int
        var folder = ""
    }

    private let render: @Sendable (WallpaperPreviewKey) async -> CGImage?
    private var images: [String: CGImage] = [:]
    private var ids: [String: String] = [:]
    private var recent: [String] = []
    private var wanted: [WallpaperPreviewKey] = []
    private var queue: [WallpaperPreviewKey] = []
    private var working: Task<Void, Never>?
    private var generation = 0
    private(set) var windows: [String: Window] = [:]
    var demanded = false {
        didSet { if !demanded, oldValue { reset() } }
    }

    var onChange: (@MainActor () -> Void)?

    init(render: @escaping @Sendable (WallpaperPreviewKey) async -> CGImage?) {
        self.render = render
    }

    var count: Int {
        images.count
    }

    func bitmap(_ id: String) -> CGImage? {
        images[id]
    }

    func ready(_ url: URL, width: Int, display: WallpaperDisplay, placement: WallpaperPlacement) -> String? {
        guard let id = ids[Self.slot(url, width: width, display: display, placement: placement)] else { return nil }
        return images[id] == nil ? nil : id
    }

    func window(for entry: WallpaperManager.Entry) -> Window {
        Self.window(for: entry, saved: windows[entry.display.key])
    }

    nonisolated static func window(for entry: WallpaperManager.Entry, saved: Window?) -> Window {
        let files = entry.files
        var window = saved.flatMap { $0.folder == entry.folder.path ? $0 : nil } ?? {
            let index = entry.currentName.flatMap { files.firstIndex(of: $0) } ?? 0
            return Window(offset: index / Self.defaultWindow * Self.defaultWindow, count: Self.defaultWindow)
        }()
        if window.offset >= files.count {
            window.offset = files.isEmpty ? 0 : (files.count - 1) / window.count * window.count
        }
        window.folder = entry.folder.path
        return window
    }

    func setWindow(_ window: Window, for entry: WallpaperManager.Entry) {
        windows[entry.display.key] = Window(
            offset: max(0, window.offset), count: min(max(window.count, 1), Self.pageLimit),
            folder: entry.folder.path
        )
    }

    func settle() async {
        while let task = working {
            await task.value
            if working == task { working = nil }
        }
    }

    private static func slot(
        _ url: URL, width: Int, display: WallpaperDisplay, placement: WallpaperPlacement
    ) -> String {
        "\(display.key)|\(width)|\(placement.rawValue)|\(url.standardizedFileURL.path)"
    }

    func retain(
        entries: [WallpaperManager.Entry], stamps: [String: WallpaperFileStamp], placement: WallpaperPlacement
    ) {
        guard demanded else { return }
        var keys: [WallpaperPreviewKey] = []
        var slots: [String: String] = [:]
        func want(_ url: URL, width: Int, display: WallpaperDisplay) {
            guard let stamp = stamps[url.standardizedFileURL.path] else { return }
            let key = WallpaperPreviewKey(file: stamp, width: width, display: display.size, placement: placement)
            keys.append(key)
            slots[Self.slot(url, width: width, display: display, placement: placement)] = key.id
        }
        for entry in entries {
            if let current = entry.display.current ?? entry.display.thumbnail {
                want(current, width: Self.cardWidth, display: entry.display)
            }
            for name in visible(entry) {
                want(entry.folder.appendingPathComponent(name), width: Self.gridWidth, display: entry.display)
            }
        }
        wanted = keys
        ids = slots
        let ids = Set(keys.map(\.id))
        let removed = images.keys.filter { !ids.contains($0) }
        for id in removed {
            images.removeValue(forKey: id)
        }
        recent.removeAll { !ids.contains($0) }
        queue = keys.filter { images[$0.id] == nil }
        if !removed.isEmpty { onChange?() }
        work()
    }

    func reset() {
        generation += 1
        working?.cancel()
        working = nil
        images = [:]
        ids = [:]
        recent = []
        wanted = []
        queue = []
    }

    func visible(_ entry: WallpaperManager.Entry) -> ArraySlice<String> {
        Self.visible(entry, in: window(for: entry))
    }

    nonisolated static func visible(_ entry: WallpaperManager.Entry, in window: Window) -> ArraySlice<String> {
        let start = min(window.offset, entry.files.count)
        return entry.files[start ..< min(entry.files.count, start + window.count)]
    }

    private func work() {
        guard working == nil, !queue.isEmpty else { return }
        let generation = generation
        working = Task { @MainActor [weak self, render] in
            while let self, generation == self.generation, !self.queue.isEmpty {
                let key = self.queue.removeFirst()
                guard self.images[key.id] == nil else { continue }
                let image = await render(key)
                guard generation == self.generation, self.wanted.contains(key) else { continue }
                if let image {
                    self.store(image, id: key.id)
                    self.onChange?()
                }
            }
            if let self, generation == self.generation { self.working = nil }
        }
    }

    private func store(_ image: CGImage, id: String) {
        images[id] = image
        recent.removeAll { $0 == id }
        recent.append(id)
        while recent.count > Self.limit {
            images.removeValue(forKey: recent.removeFirst())
        }
    }
}
