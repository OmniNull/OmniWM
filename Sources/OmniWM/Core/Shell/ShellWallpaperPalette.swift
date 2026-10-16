// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
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

    init(
        destination: URL,
        scheme: ShellWallpaperScheme,
        image: @escaping @MainActor () -> CGImage? = {
            OverviewWallpaperCache().image(for: CGMainDisplayID(), maxPixelSize: ShellWallpaperPalette.pixelSize)
        },
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        self.destination = destination
        self.scheme = scheme
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
    }

    func refresh() {
        guard let image = image() else {
            onFailure("The wallpaper palette keeps its last colors because the wallpaper image is unavailable")
            return
        }
        let pixels = ShellWallpaperPalette.pixels(of: image)
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
        observation?.sync(paths: [Self.store, Self.store.appendingPathComponent("Index.plist")])
    }
}
