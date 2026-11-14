// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMMaterialColor

struct ShellWallpaperPaletteOverride: Equatable, Sendable {
    let file: WallpaperFileStamp
    let pixels: [UInt32]

    func pixels(for source: ShellWallpaperPalette.Source) -> [UInt32]? {
        guard case let .still(still, _) = source, still.url.standardizedFileURL.path == file.path,
              still.size == file.bytes, still.modified.timeIntervalSince1970 == file.modified
        else { return nil }
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
            guard let offset = Int(words[2]), let count = Int(words[3]), offset >= 0,
                  (1 ... WallpaperPreviews.pageLimit).contains(count)
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
    static let nameBudget = 48 * 1024

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
        var kind = "file"
        var shown: String?
        var problem: String?
        var offset: Int
        var page: Int
        var items: [String]
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
    var defaultPage = WallpaperPreviews.defaultWindow
    var rotations = SettingsExport.Wallpaper.rotationPresets
    var displays: [Display] = []
    var swatches: [Swatch] = []

    static func items(_ names: ArraySlice<String>) -> (items: [String], truncated: Bool) {
        var budget = nameBudget
        var items: [String] = []
        for name in names {
            var scratch = ShellValueWriter()
            scratch.string(name)
            budget -= scratch.bytes.count
            guard budget >= 0 else { break }
            items.append(name)
        }
        return (items, items.count < names.count)
    }

    func write(into writer: inout ShellValueWriter) {
        writer.map(10)
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
        writer.key("defaultPage")
        writer.number(Double(defaultPage))
        writer.key("rotations")
        writer.array(rotations.count)
        for minutes in rotations {
            writer.number(Double(minutes))
        }
        writer.key("displays")
        writer.array(displays.count)
        for display in displays {
            write(display, into: &writer)
        }
        writer.key("schemes")
        writer.array(swatches.count)
        for swatch in swatches {
            writer.map(3)
            writer.key("name")
            writer.string(swatch.scheme)
            writer.key("light")
            Self.write(swatch.light, into: &writer)
            writer.key("dark")
            Self.write(swatch.dark, into: &writer)
        }
    }

    private static func write(_ strings: [String], into writer: inout ShellValueWriter) {
        writer.array(strings.count)
        for string in strings {
            writer.string(string)
        }
    }

    private func write(_ display: Display, into writer: inout ShellValueWriter) {
        writer.map(18)
        Self.write("id", display.id, into: &writer)
        Self.write("name", display.name, into: &writer)
        Self.write("folder", display.folder, into: &writer)
        Self.write("kind", display.kind, into: &writer)
        Self.write("current", display.current, into: &writer)
        Self.write("shown", display.shown, into: &writer)
        Self.write("problem", display.problem, into: &writer)
        Self.write("main", display.main, into: &writer)
        Self.write("builtin", display.builtin, into: &writer)
        Self.write("notch", display.notch, into: &writer)
        Self.write("custom", display.custom, into: &writer)
        Self.write("truncated", display.truncated, into: &writer)
        Self.write("w", display.width, into: &writer)
        Self.write("h", display.height, into: &writer)
        Self.write("count", Double(display.count), into: &writer)
        Self.write("offset", Double(display.offset), into: &writer)
        Self.write("page", Double(display.page), into: &writer)
        writer.key("items")
        Self.write(display.items, into: &writer)
    }

    private static func write(_ key: String, _ value: String?, into writer: inout ShellValueWriter) {
        writer.key(key)
        value.map { writer.string($0) } ?? writer.null()
    }

    private static func write(_ key: String, _ value: Bool, into writer: inout ShellValueWriter) {
        writer.key(key)
        writer.bool(value)
    }

    private static func write(_ key: String, _ value: Double, into writer: inout ShellValueWriter) {
        writer.key(key)
        writer.number(value)
    }
}

struct ShellWallpaperPreviews: Equatable, Sendable, ShellValueWritable {
    struct Display: Equatable, Sendable {
        var card: String?
        var items: [String: String] = [:]
    }

    var displays: [String: Display] = [:]

    func write(into writer: inout ShellValueWriter) {
        writer.map(displays.count)
        for (id, display) in displays {
            writer.key(id)
            writer.map(2)
            writer.key("card")
            display.card.map { writer.string($0) } ?? writer.null()
            writer.key("items")
            writer.map(display.items.count)
            for (name, preview) in display.items {
                writer.key(name)
                writer.string(preview)
            }
        }
    }
}

extension ShellWallpaperPalette {
    static let swatchRoles: [ShellRole] = [.accent, .secondaryAccent, .tertiaryAccent, .surface]

    static func swatches(pixels: [UInt32]) -> [ShellWallpaper.Swatch] {
        let seed = seed(of: pixels)
        return ShellWallpaperScheme.allCases.map { scheme in
            let (source, variant) = material(seed: seed, scheme: scheme)
            func colors(dark: Bool) -> [String] {
                let roles = ShellMaterialPalette.colors(seed: source, variant: variant, dark: dark)
                return swatchRoles.map { "#" + String(format: "%06X", roles[$0] ?? 0) }
            }
            return ShellWallpaper.Swatch(scheme: scheme.rawValue, light: colors(dark: false), dark: colors(dark: true))
        }
    }
}
