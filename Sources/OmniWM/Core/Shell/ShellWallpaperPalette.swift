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

    @MainActor
    static func image(
        for displayId: CGDirectDisplayID,
        frame: CGRect? = nil,
        cache: OverviewWallpaperCache = OverviewWallpaperCache(),
        windows: () -> [[String: Any]] = {
            CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        },
        store: () -> Data? = {
            try? Data(contentsOf: ShellWallpaperPaletteWriter.store.appendingPathComponent("Index.plist"))
        },
        location: (CGDirectDisplayID) -> (display: String, space: String)? = { displayId in
            SkyLight.displayUUID(for: displayId).flatMap { display in
                SkyLight.shared.currentSpaceUUID(forDisplay: display).map { (display, $0) }
            }
        }
    ) -> CGImage? {
        let frame = frame ?? CGDisplayBounds(displayId)
        if let url = cache.desktopImageURL(displayId),
           let location = location(displayId),
           showsStillImage(url, windows: windows(), frame: frame, store: store(), location: location),
           let image = cache.fileImage(for: displayId, maxPixelSize: pixelSize)
        {
            return image
        }
        return cache.image(for: displayId, maxPixelSize: pixelSize, frame: frame)
    }

    @MainActor
    static func showsStillImage(
        _ url: URL,
        windows: [[String: Any]],
        frame: CGRect,
        store: Data?,
        location: (display: String, space: String)
    ) -> Bool {
        guard url.isFileURL,
              let wallpaper = SkyLight.wallpaperWindow(in: windows, frame: frame),
              windows.contains(where: {
                  $0[kCGWindowNumber as String] as? UInt32 == wallpaper.id
                      && $0[kCGWindowLayer as String] as? Int32 == CGWindowLevelForKey(.desktopWindow) - 1
              }),
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

    private static func stillImagePath(of content: [String: Any]) -> String? {
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
    static let store = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store", isDirectory: true)
    private static let queue = DispatchQueue(label: "com.barut.OmniWM.shell.wallpaper", qos: .utility)

    private let destination: URL
    private let image: @MainActor () -> CGImage?
    private let onFailure: @MainActor (String) -> Void
    private var observation: ShellDirectoryObservation?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var scheme: ShellWallpaperScheme
    private let recheckInterval: TimeInterval
    private var recheck: DispatchSourceTimer?
    private var pixels: [UInt32]?

    init(
        destination: URL,
        scheme: ShellWallpaperScheme,
        recheckInterval: TimeInterval = 60,
        image: @escaping @MainActor () -> CGImage? = { ShellWallpaperPalette.image(for: CGMainDisplayID()) },
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        self.destination = destination
        self.scheme = scheme
        self.recheckInterval = recheckInterval
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
        guard let image = image() else {
            onFailure("The wallpaper palette keeps its last colors because the wallpaper image is unavailable")
            return
        }
        let pixels = ShellWallpaperPalette.pixels(of: image)
        guard !onlyIfChanged || pixels != self.pixels else { return }
        self.pixels = pixels
        let scheme = scheme
        let destination = destination
        Self.queue.async {
            do {
                _ = try ShellWallpaperPalette.write(
                    ShellWallpaperPalette.theme(pixels: pixels, scheme: scheme),
                    to: destination
                )
            } catch {
                Log.shell.error("Failed to write the wallpaper palette: \(error.localizedDescription)")
            }
        }
    }

    private func watchStore() {
        observation?.sync(
            paths: [Self.store, Self.store.appendingPathComponent("Index.plist")], recursivePaths: [Self.store]
        )
    }
}
