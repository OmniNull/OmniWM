// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMMaterialColor

struct ShellWallpaperPaletteOverride: Equatable, Sendable {
    let url: URL
    let pixels: [UInt32]

    func pixels(for source: ShellWallpaperPalette.Source) -> [UInt32]? {
        guard case let .still(still, _) = source, still.url.standardizedFileURL == url.standardizedFileURL else {
            return nil
        }
        return pixels
    }
}

enum ShellWallpaperCommand: Equatable, Sendable {
    case next(WallpaperTarget)
    case set(display: String, name: String)
    case page(display: String, offset: Int, count: Int)
    case rotation(minutes: Int)
    case reveal(display: String)
    case chooseFolder(display: String)
    case resetFolder(display: String)
    case scheme(ShellWallpaperScheme)
    case settings

    init?(words: [String]) {
        switch words {
        case ["next"],
             ["next", "all"]: self = .next(.all)
        case ["settings"]: self = .settings
        case let words where words.count == 2 && words[0] == "next":
            guard Self.isDisplay(words[1]) else { return nil }
            self = .next(.display(words[1]))
        case let words where words.count == 2 && words[0] == "rotation":
            guard let minutes = words[1] == "off" ? 0 : Int(words[1]),
                  (0 ... SettingsExport.Wallpaper.rotationLimit).contains(minutes)
            else { return nil }
            self = .rotation(minutes: minutes)
        case let words where words.count == 2 && words[0] == "scheme":
            guard let scheme = ShellWallpaperScheme(rawValue: words[1]) else { return nil }
            self = .scheme(scheme)
        default:
            guard let command = Self.displayCommand(words) else { return nil }
            self = command
        }
    }

    private static func displayCommand(_ words: [String]) -> Self? {
        guard words.count >= 2, isDisplay(words[1]) else { return nil }
        switch (words[0], words.count) {
        case ("open", 2): return .reveal(display: words[1])
        case ("folder", 2): return .chooseFolder(display: words[1])
        case ("folder", 3) where words[2] == "reset": return .resetFolder(display: words[1])
        case ("set", 3):
            guard let name = WallpaperLibrary.name(forToken: words[2]), WallpaperLibrary.isImage(name) else {
                return nil
            }
            return .set(display: words[1], name: name)
        case ("page", 4):
            guard let offset = Int(words[2]), let count = Int(words[3]), offset >= 0, (1 ... 24).contains(count)
            else { return nil }
            return .page(display: words[1], offset: offset, count: count)
        default: return nil
        }
    }

    private static func isDisplay(_ word: String) -> Bool {
        guard word.hasPrefix("display:"), let id = UInt32(word.dropFirst("display:".count)) else { return false }
        return id > 0
    }
}

struct ShellWallpaper: Equatable, Sendable, ShellValueWritable {
    static let itemLimit = 1000
    static let nameBudget = 48 * 1024

    struct Item: Equatable, Sendable {
        var name: String
        var preview: String?
    }

    struct Display: Equatable, Sendable {
        var id: String
        var name: String
        var main: Bool
        var builtin: Bool
        var notch: Bool
        var width: Double
        var height: Double
        var folder: String
        var custom: Bool
        var count: Int
        var current: String?
        var preview: String?
        var offset: Int
        var items: [Item]
        var truncated: Bool
    }

    struct Swatch: Equatable, Sendable {
        var scheme: String
        var light: [String]
        var dark: [String]
    }

    var enabled = false
    var rotation = 0
    var next: Double?
    var palette = false
    var scheme = ShellWallpaperScheme.tonalSpot.rawValue
    var problem: String?
    var displays: [Display] = []
    var swatches: [Swatch] = []

    static func items(_ names: [String], preview: (String) -> String?) -> (items: [Item], truncated: Bool) {
        var budget = nameBudget
        var items: [Item] = []
        for name in names.prefix(itemLimit) {
            let item = Item(name: name, preview: preview(name))
            var scratch = ShellValueWriter()
            write(item, into: &scratch)
            budget -= scratch.bytes.count
            guard budget >= 0 else { break }
            items.append(item)
        }
        return (items, items.count < names.count)
    }

    func write(into writer: inout ShellValueWriter) {
        writer.map(8)
        writer.key("enabled")
        writer.bool(enabled)
        writer.key("rotation")
        writer.number(Double(rotation))
        writer.key("next")
        next.map { writer.number($0) } ?? writer.null()
        writer.key("palette")
        writer.bool(palette)
        writer.key("scheme")
        writer.string(scheme)
        writer.key("problem")
        problem.map { writer.string($0) } ?? writer.null()
        writer.key("displays")
        writer.array(displays.count)
        displays.forEach { write($0, into: &writer) }
        writer.key("schemes")
        writer.array(swatches.count)
        for swatch in swatches {
            writer.map(3)
            writer.key("name")
            writer.string(swatch.scheme)
            for (key, colors) in [("light", swatch.light), ("dark", swatch.dark)] {
                writer.key(key)
                writer.array(colors.count)
                colors.forEach { writer.string($0) }
            }
        }
    }

    private func write(_ display: Display, into writer: inout ShellValueWriter) {
        writer.map(15)
        for (key, value) in [("id", display.id), ("name", display.name), ("folder", display.folder)] {
            writer.key(key)
            writer.string(value)
        }
        for (key, value) in [
            ("main", display.main), ("builtin", display.builtin), ("notch", display.notch),
            ("custom", display.custom), ("truncated", display.truncated)
        ] {
            writer.key(key)
            writer.bool(value)
        }
        for (key, value) in [
            ("w", display.width), ("h", display.height), ("count", Double(display.count)),
            ("offset", Double(display.offset))
        ] {
            writer.key(key)
            writer.number(value)
        }
        for (key, value) in [("current", display.current), ("preview", display.preview)] {
            writer.key(key)
            value.map { writer.string($0) } ?? writer.null()
        }
        writer.key("items")
        writer.array(display.items.count)
        display.items.forEach { Self.write($0, into: &writer) }
    }

    static func write(_ item: Item, into writer: inout ShellValueWriter) {
        writer.map(2)
        writer.key("name")
        writer.string(item.name)
        writer.key("preview")
        item.preview.map { writer.string($0) } ?? writer.null()
    }
}

extension ShellWallpaperPalette {
    static let swatchRoles: [ShellRole] = [.accent, .secondaryAccent, .tertiaryAccent, .surface]

    static func swatches(pixels: [UInt32]) -> [ShellWallpaper.Swatch] {
        let seed = pixels.withUnsafeBufferPointer { omni_material_seed($0.baseAddress, $0.count, 0) }
        return ShellWallpaperScheme.allCases.map { scheme in
            let variant = seed == 0 ? OMNI_MATERIAL_MONOCHROME : scheme.variant
            let source = seed == 0 ? 0xFF80_8080 : seed
            func colors(dark: Bool) -> [String] {
                let roles = ShellMaterialPalette.colors(seed: source, variant: variant, dark: dark)
                return swatchRoles.map { "#" + String(format: "%06X", roles[$0] ?? 0) }
            }
            return ShellWallpaper.Swatch(scheme: scheme.rawValue, light: colors(dark: false), dark: colors(dark: true))
        }
    }
}
