// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ImageIO
import OmniWMMaterialColor

enum ShellWallpaperScheme: String, CaseIterable, Sendable {
    case tonalSpot
    case content
    case vibrant
    case expressive
    case fidelity
    case fruitSalad
    case rainbow
    case neutral
    case monochrome

    var variant: omni_material_variant {
        switch self {
        case .tonalSpot: OMNI_MATERIAL_TONAL_SPOT
        case .content: OMNI_MATERIAL_CONTENT
        case .vibrant: OMNI_MATERIAL_VIBRANT
        case .expressive: OMNI_MATERIAL_EXPRESSIVE
        case .fidelity: OMNI_MATERIAL_FIDELITY
        case .fruitSalad: OMNI_MATERIAL_FRUIT_SALAD
        case .rainbow: OMNI_MATERIAL_RAINBOW
        case .neutral: OMNI_MATERIAL_NEUTRAL
        case .monochrome: OMNI_MATERIAL_MONOCHROME
        }
    }
}

enum ShellWallpaperPalette {
    static let themeName = "wallpaper"
    static let pixelSize = 128
    private static let gray: UInt32 = 0xFF80_8080

    static func pixels(of image: CGImage) -> [UInt32] {
        let scale = min(1, Double(pixelSize) / Double(max(image.width, image.height, 1)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: buffer.baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue
                  )
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : []
    }

    static func theme(pixels: [UInt32], scheme: ShellWallpaperScheme) -> String {
        let seed = pixels.withUnsafeBufferPointer { omni_material_seed($0.baseAddress, $0.count, 0) }
        let (source, variant) = seed == 0 ? (gray, OMNI_MATERIAL_MONOCHROME) : (seed, scheme.variant)
        var text = ""
        for (name, dark) in [("light", false), ("dark", true)] {
            let colors = ShellMaterialPalette.colors(seed: source, variant: variant, dark: dark)
            text += text.isEmpty ? "[\(name)]\n" : "\n[\(name)]\n"
            for role in ShellRole.allCases {
                guard let color = colors[role] else { continue }
                text += "\(role) = \"#\(String(format: "%06X", color))\"\n"
            }
        }
        return text
    }

    static func write(_ text: String, to url: URL) throws -> Bool {
        guard (try? Data(contentsOf: url)) != Data(text.utf8) else { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        return true
    }
}

extension ShellWallpaperPalette {
    static let stillImageProvider = "com.apple.wallpaper.choice.image"
    static let aerialProvider = "com.apple.wallpaper.choice.aerials"
    static let aerials = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)

    enum DesktopChoice: Equatable, Sendable {
        case file(URL)
        case aerial(asset: String, thumbnail: URL?)
        case shuffle
        case other
    }

    struct StillWallpaper: Equatable, Sendable {
        let url: URL
        let size: Int64
        let modified: Date
    }

    struct StillProbe: Sendable {
        let url: URL?
        let showsWallpaperWindow: Bool
        let location: (display: String, space: String)?
    }

    @MainActor
    static func stillWallpaper(
        for displayId: CGDirectDisplayID,
        frame: CGRect? = nil,
        desktopImageURL: (CGDirectDisplayID) -> URL? = { displayId in
            NSScreen.screens.first { $0.displayId == displayId }.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        },
        windows: () -> [[String: Any]] = {
            CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        },
        store: () -> Data? = { ShellWallpaperPalette.storeIndex() },
        location: (CGDirectDisplayID) -> (display: String, space: String)? = { ShellWallpaperPalette.location(of: $0) },
        aerials: URL = Self.aerials
    ) -> StillWallpaper? {
        let probe = stillProbe(
            for: displayId, frame: frame, desktopImageURL: desktopImageURL, windows: windows, location: location
        )
        return stillWallpaper(probe, store: store(), aerials: aerials)
    }

    @MainActor
    static func stillProbe(
        for displayId: CGDirectDisplayID,
        frame: CGRect? = nil,
        desktopImageURL: (CGDirectDisplayID) -> URL? = { displayId in
            NSScreen.screens.first { $0.displayId == displayId }.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        },
        windows: () -> [[String: Any]] = {
            CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        },
        location: (CGDirectDisplayID) -> (display: String, space: String)? = { ShellWallpaperPalette.location(of: $0) }
    ) -> StillProbe {
        StillProbe(
            url: desktopImageURL(displayId),
            showsWallpaperWindow: showsWallpaperWindow(windows(), frame: frame ?? CGDisplayBounds(displayId)),
            location: location(displayId)
        )
    }

    static func stillWallpaper(_ probe: StillProbe, store: Data?, aerials: URL = Self.aerials) -> StillWallpaper? {
        guard let location = probe.location else { return nil }
        if case let .aerial(_, thumbnail?) = desktopChoice(store: store, location: location, aerials: aerials) {
            return stamp(thumbnail)
        }
        guard let url = probe.url, probe.showsWallpaperWindow,
              showsStillImage(url, store: store, location: location)
        else { return nil }
        return stamp(url)
    }

    static func storeIndex() -> Data? {
        try? Data(contentsOf: ShellWallpaperPaletteWriter.store.appendingPathComponent("Index.plist"))
    }

    @MainActor
    static func location(of displayId: CGDirectDisplayID) -> (display: String, space: String)? {
        SkyLight.displayUUID(for: displayId).flatMap { display in
            SkyLight.shared.currentSpaceUUID(forDisplay: display).map { (display, $0) }
        }
    }

    private static func stamp(_ url: URL) -> StillWallpaper? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return StillWallpaper(url: url, size: size, modified: modified)
    }

    @MainActor
    static func screenImage(
        for displayId: CGDirectDisplayID,
        store: () -> Data? = { ShellWallpaperPalette.storeIndex() },
        location: (CGDirectDisplayID) -> (display: String, space: String)? = { ShellWallpaperPalette.location(of: $0) },
        aerials: URL = Self.aerials,
        capture: (CGDirectDisplayID) -> CGImage? = { displayId in
            guard ScreenCapturePermissionMonitor.shared.isGranted else { return nil }
            let frame = CGDisplayBounds(displayId)
            return SkyLight.shared.captureWallpaper(in: frame).flatMap {
                $0.width >= Int(ceil(frame.width)) && $0.height >= Int(ceil(frame.height)) ? $0 : nil
            }
        },
        fallback: (CGDirectDisplayID) -> CGImage? = {
            OverviewWallpaperCache().image(for: $0, maxPixelSize: ShellWallpaperPalette.pixelSize)
        }
    ) -> CGImage? {
        if let location = location(displayId),
           case .aerial = desktopChoice(store: store(), location: location, aerials: aerials)
        {
            return capture(displayId)
        }
        return fallback(displayId)
    }

    static func desktopChoice(
        store: Data?,
        location: (display: String, space: String),
        aerials: URL
    ) -> DesktopChoice? {
        guard let store,
              let index = try? PropertyListSerialization.propertyList(from: store, format: nil) as? [String: Any],
              let content = desktopContent(in: index, location: location)
        else { return nil }
        if let path = stillImagePath(of: content) {
            return .file(URL(fileURLWithPath: path))
        }
        guard let choices = content["Choices"] as? [[String: Any]], choices.count == 1 else { return .other }
        if content["Shuffle"] as? String != "$null" {
            return .shuffle
        }
        guard choices[0]["Provider"] as? String == aerialProvider,
              let data = choices[0]["Configuration"] as? Data,
              let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any],
              let asset = configuration["assetID"] as? String,
              !asset.isEmpty, !asset.contains("/")
        else { return .other }
        let thumbnail = aerials.appendingPathComponent("thumbnails/\(asset).png").standardizedFileURL
        return .aerial(
            asset: asset,
            thumbnail: FileManager.default.fileExists(atPath: thumbnail.path) ? thumbnail : nil
        )
    }

    static func read(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    @MainActor
    static func showsWallpaperWindow(_ windows: [[String: Any]], frame: CGRect) -> Bool {
        guard let wallpaper = SkyLight.wallpaperWindow(in: windows, frame: frame) else { return false }
        return windows.contains {
            $0[kCGWindowNumber as String] as? UInt32 == wallpaper.id
                && $0[kCGWindowLayer as String] as? Int32 == CGWindowLevelForKey(.desktopWindow) - 1
        }
    }

    static func showsStillImage(
        _ url: URL,
        store: Data?,
        location: (display: String, space: String)
    ) -> Bool {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let store,
              let index = try? PropertyListSerialization.propertyList(from: store, format: nil) as? [String: Any],
              let content = desktopContent(in: index, location: location)
        else { return false }
        return stillImagePath(of: content) == url.standardizedFileURL.path
    }

    static func desktopContent(
        in index: [String: Any],
        location: (display: String, space: String)
    ) -> [String: Any]? {
        let space = (index["Spaces"] as? [String: Any])?[location.space] as? [String: Any]
        let entries: [Any?] = [
            (space?["Displays"] as? [String: Any])?[location.display],
            space?["Default"],
            (index["Displays"] as? [String: Any])?[location.display],
            index["AllSpacesAndDisplays"],
            index["SystemDefault"]
        ]
        return entries.lazy.compactMap { (($0 as? [String: Any])?["Desktop"] as? [String: Any])?["Content"] }
            .first as? [String: Any]
    }

    static func stillImagePath(of content: [String: Any]) -> String? {
        guard content["Shuffle"] as? String == "$null",
              let choices = content["Choices"] as? [[String: Any]], choices.count == 1,
              choices[0]["Provider"] as? String == stillImageProvider,
              let data = choices[0]["Configuration"] as? Data,
              let configuration = try? PropertyListSerialization
                  .propertyList(from: data, format: nil) as? [String: Any],
              configuration["type"] as? String == "imageFile",
              let relative = (configuration["url"] as? [String: Any])?["relative"] as? String,
              let url = URL(string: relative), url.isFileURL
        else { return nil }
        return url.standardizedFileURL.path
    }
}

@MainActor
final class ShellWallpaperPaletteWriter {
    nonisolated static let store = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store", isDirectory: true)
    private static let queue = DispatchQueue(label: "com.barut.OmniWM.shell.wallpaper", qos: .utility)

    typealias StillLookup = @Sendable () -> ShellWallpaperPalette.StillWallpaper?

    // Read and written only on the writer queue.
    private final class Record: @unchecked Sendable {
        var written: ShellWallpaperPalette.StillWallpaper?
        var pixels: [UInt32]?
    }

    private let destination: URL
    private let still: @MainActor () -> StillLookup
    private let read: @Sendable (URL) -> CGImage?
    private let image: @MainActor () -> CGImage?
    private let onFailure: @MainActor (String) -> Void
    private var observation: ShellDirectoryObservation?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var scheme: ShellWallpaperScheme
    private let recheckInterval: TimeInterval
    private var recheck: DispatchSourceTimer?
    private let record = Record()

    init(
        destination: URL,
        scheme: ShellWallpaperScheme,
        recheckInterval: TimeInterval = 60,
        still: @escaping @MainActor () -> StillLookup = {
            let probe = ShellWallpaperPalette.stillProbe(for: CGMainDisplayID())
            return { ShellWallpaperPalette.stillWallpaper(probe, store: ShellWallpaperPalette.storeIndex()) }
        },
        read: @escaping @Sendable (URL) -> CGImage? = { ShellWallpaperPalette.read($0) },
        image: @escaping @MainActor () -> CGImage? = { ShellWallpaperPalette.screenImage(for: CGMainDisplayID()) },
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        self.destination = destination
        self.scheme = scheme
        self.recheckInterval = recheckInterval
        self.still = still
        self.read = read
        self.image = image
        self.onFailure = onFailure
    }

    isolated deinit {
        stop()
    }

    func start() {
        guard observation == nil else { return }
        observation = ShellDirectoryObservation { [weak self] in
            self?.watchStore()
            self?.refresh()
        }
        watchStore()
        observers = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
        ].map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        let recheck = DispatchSource.makeTimerSource(queue: .main)
        recheck.schedule(
            deadline: .now() + recheckInterval,
            repeating: recheckInterval,
            leeway: .milliseconds(Int(recheckInterval * 100))
        )
        recheck.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh(onlyIfChanged: true) }
        }
        recheck.resume()
        self.recheck = recheck
        refresh()
    }

    func setScheme(_ next: ShellWallpaperScheme) {
        guard next != scheme else { return }
        scheme = next
        refresh()
    }

    func stop() {
        observation?.cancel()
        observation = nil
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers = []
        recheck?.cancel()
        recheck = nil
    }

    func refresh() {
        refresh(onlyIfChanged: false)
    }

    private func refresh(onlyIfChanged: Bool) {
        let lookup = still()
        let read = read
        let scheme = scheme
        let destination = destination
        let record = record
        Self.queue.async { [weak self] in
            guard let still = lookup() else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.refreshImage(onlyIfChanged: onlyIfChanged) }
                }
                return
            }
            guard !onlyIfChanged || still != record.written || !Self.exists(destination) else { return }
            guard let image = read(still.url) else {
                Log.shell.error("Failed to read the wallpaper file for the wallpaper palette")
                return
            }
            do {
                _ = try ShellWallpaperPalette.write(
                    ShellWallpaperPalette.theme(pixels: ShellWallpaperPalette.pixels(of: image), scheme: scheme),
                    to: destination
                )
                record.written = still
                record.pixels = nil
            } catch {
                Log.shell.error("Failed to write the wallpaper palette: \(error.localizedDescription)")
            }
        }
    }

    private func refreshImage(onlyIfChanged: Bool) {
        guard !onlyIfChanged || recheck != nil else { return }
        guard let image = image() else {
            onFailure("The wallpaper palette keeps its last colors because the wallpaper image is unavailable")
            return
        }
        let pixels = ShellWallpaperPalette.pixels(of: image)
        let scheme = scheme
        let destination = destination
        let record = record
        Self.queue.async {
            guard !onlyIfChanged || pixels != record.pixels || !Self.exists(destination) else { return }
            do {
                _ = try ShellWallpaperPalette.write(
                    ShellWallpaperPalette.theme(pixels: pixels, scheme: scheme),
                    to: destination
                )
                record.pixels = pixels
                record.written = nil
            } catch {
                Log.shell.error("Failed to write the wallpaper palette: \(error.localizedDescription)")
            }
        }
    }

    private nonisolated static func exists(_ destination: URL) -> Bool {
        FileManager.default.fileExists(atPath: destination.path)
    }

    private func watchStore() {
        observation?.sync(
            paths: [Self.store, Self.store.appendingPathComponent("Index.plist")], recursivePaths: [Self.store]
        )
    }
}
