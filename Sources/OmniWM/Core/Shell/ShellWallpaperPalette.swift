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
        case aerial(asset: String?, thumbnail: URL?)
        case shuffle
        case other
    }

    struct StillWallpaper: Equatable, Sendable {
        let url: URL
        let size: Int64
        let modified: Date
    }

    struct StillProbe: Sendable {
        let showsWallpaperWindow: Bool
        let location: (display: String, space: String)?
    }

    enum Source: Equatable, Sendable {
        case still(StillWallpaper, aerial: Bool)
        case capture(aerial: Bool)
    }

    @MainActor
    static func stillProbe(
        for displayId: CGDirectDisplayID,
        frame: CGRect? = nil,
        windows: () -> [[String: Any]] = {
            CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        },
        location: (CGDirectDisplayID) -> (display: String, space: String)? = { ShellWallpaperPalette.location(of: $0) }
    ) -> StillProbe {
        StillProbe(
            showsWallpaperWindow: showsWallpaperWindow(windows(), frame: frame ?? CGDisplayBounds(displayId)),
            location: location(displayId)
        )
    }

    static func source(_ probe: StillProbe, store: Data?, aerials: URL = Self.aerials) -> Source {
        guard let location = probe.location,
              let choice = desktopChoice(store: store, location: location, aerials: aerials)
        else { return .capture(aerial: false) }
        switch choice {
        case let .aerial(_, thumbnail):
            guard probe.showsWallpaperWindow, let thumbnail, let still = stamp(thumbnail) else {
                return .capture(aerial: true)
            }
            return .still(still, aerial: true)
        case let .file(chosen):
            guard probe.showsWallpaperWindow, isSingleImage(chosen), let still = stamp(chosen)
            else { return .capture(aerial: false) }
            return .still(still, aerial: false)
        case .shuffle,
             .other:
            return .capture(aerial: false)
        }
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
        aerial: Bool,
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
        aerial ? capture(displayId) : fallback(displayId)
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
        guard let choices = content["Choices"] as? [[String: Any]], let choice = choices.first else { return .other }
        let isAerial = choices.allSatisfy { $0["Provider"] as? String == aerialProvider }
        if content["Shuffle"] as? String != "$null" {
            return isAerial ? .aerial(asset: nil, thumbnail: nil) : .shuffle
        }
        guard isAerial else { return .other }
        guard choices.count == 1,
              let data = choice["Configuration"] as? Data,
              let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any],
              let asset = configuration["assetID"] as? String,
              !asset.isEmpty, !asset.contains("/")
        else { return .aerial(asset: nil, thumbnail: nil) }
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

    static func isSingleImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) == 1
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
        return entries.lazy.compactMap { candidate -> Any? in
            guard let entry = candidate as? [String: Any] else { return nil }
            let slot = entry["Type"] as? String == "linked" ? "Linked" : "Desktop"
            return (entry[slot] as? [String: Any])?["Content"]
        }.first as? [String: Any]
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
