// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct WallpaperPreviewKey: Hashable, Sendable {
    let file: WallpaperFileStamp
    let width: Int
    let ratio: Int
    let placement: WallpaperPlacement

    init(_ url: URL, width: Int, display size: CGSize, placement: WallpaperPlacement) {
        file = WallpaperFileStamp(url)
        self.width = width
        let aspect = size.width > 0 && size.height > 0 ? size.width / size.height : 16.0 / 9.0
        ratio = Int((aspect * 1000).rounded())
        self.placement = placement
    }

    var aspect: Double {
        Double(ratio) / 1000
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
    static let cardWidth = 800
    static let gridWidth = 400
    static let limit = 64
    static let defaultWindow = 6

    struct Window: Equatable {
        var offset: Int
        var count: Int
    }

    private let render: @Sendable (WallpaperPreviewKey) async -> CGImage?
    private var images: [String: CGImage] = [:]
    private var recent: [String] = []
    private var wanted: [WallpaperPreviewKey] = []
    private var queue: [WallpaperPreviewKey] = []
    private var working: Task<Void, Never>?
    private var generation = 0
    private var windows: [String: Window] = [:]
    private var lastEntries: [WallpaperManager.Entry] = []
    private var lastPlacement = WallpaperPlacement.fill
    var demanded = false {
        didSet {
            guard demanded != oldValue else { return }
            if demanded { retain(entries: lastEntries, placement: lastPlacement) } else { reset() }
        }
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
        let id = WallpaperPreviewKey(url, width: width, display: display.size, placement: placement).id
        return images[id] == nil ? nil : id
    }

    func window(for display: String) -> Window? {
        windows[display]
    }

    func setWindow(_ window: Window, for entry: WallpaperManager.Entry, placement: WallpaperPlacement) {
        let bounded = Window(offset: max(0, window.offset), count: min(max(window.count, 1), 24))
        guard windows[entry.display.key] != bounded else { return }
        windows[entry.display.key] = bounded
        retain(entries: lastEntries, placement: placement)
    }

    func retain(entries: [WallpaperManager.Entry], placement: WallpaperPlacement) {
        lastEntries = entries
        lastPlacement = placement
        guard demanded else { return }
        var keys: [WallpaperPreviewKey] = []
        for entry in entries {
            if let current = entry.display.current {
                keys.append(WallpaperPreviewKey(
                    current, width: Self.cardWidth, display: entry.display.size, placement: placement
                ))
            }
            for name in visible(entry) {
                keys.append(WallpaperPreviewKey(
                    entry.folder.appendingPathComponent(name), width: Self.gridWidth, display: entry.display.size,
                    placement: placement
                ))
            }
        }
        wanted = keys
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
        recent = []
        wanted = []
        queue = []
    }

    private func visible(_ entry: WallpaperManager.Entry) -> [String] {
        let files = entry.files
        guard !files.isEmpty else { return [] }
        let window = windows[entry.display.key] ?? {
            let index = entry.currentName.flatMap { files.firstIndex(of: $0) } ?? 0
            let size = Self.defaultWindow
            return Window(offset: index / size * size, count: size)
        }()
        let start = min(window.offset, files.count)
        let end = min(files.count, start + window.count)
        return Array(files[start ..< end].prefix(Self.limit))
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
