// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum WallpaperPlacement: String, Codable, CaseIterable, Sendable {
    case fill
    case fit
}

enum WallpaperLibrary {
    static let defaultFolder = "~/Pictures/Wallpapers"
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "gif", "bmp"
    ]

    static func isImage(_ name: String) -> Bool {
        guard !name.hasPrefix("."), !name.contains("/") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    static func files(in folder: URL) -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.compactMap { item -> String? in
            let name = item.lastPathComponent
            guard isImage(name),
                  (try? item.resolvingSymlinksInPath().resourceValues(forKeys: Set(keys)).isRegularFile) == true
            else { return nil }
            return name
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home + trimmed.dropFirst() }
        return trimmed
    }

    static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func folderURL(_ path: String, home: String = NSHomeDirectory()) -> URL? {
        let expanded = expand(path, home: home)
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }

    static func token(for name: String) -> String {
        name.utf8.map { String(format: "%02x", $0) }.joined()
    }

    static func name(forToken token: String) -> String? {
        guard token.count.isMultiple(of: 2), !token.isEmpty else { return nil }
        var bytes: [UInt8] = []
        var index = token.startIndex
        while index < token.endIndex {
            let next = token.index(index, offsetBy: 2)
            guard let byte = UInt8(token[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

struct WallpaperRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

struct WallpaperShuffle: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var folder: String
        var order: [String]
        var position: Int
        var last: String?
    }

    var displays: [String: Entry] = [:]

    mutating func next(
        display: String, folder: String, files: [String], using random: inout some RandomNumberGenerator
    ) -> String? {
        guard !files.isEmpty else { return nil }
        let available = Set(files)
        var entry = displays[display] ?? Entry(folder: folder, order: [], position: 0)
        if entry.folder != folder {
            entry = Entry(folder: folder, order: [], position: 0)
        }
        let start = min(max(entry.position, 0), entry.order.count)
        let done = Set(entry.order[..<start])
        var remaining = entry.order[start...].filter { available.contains($0) && !done.contains($0) }
        let known = Set(entry.order)
        for name in files.filter({ !known.contains($0) }).shuffled(using: &random) {
            remaining.insert(name, at: Int.random(in: 0 ... remaining.count, using: &random))
        }
        var order = entry.order[..<start].filter { available.contains($0) }
        if remaining.isEmpty {
            order = []
            remaining = files.shuffled(using: &random)
            if remaining.count > 1, remaining.first == entry.last {
                remaining.swapAt(0, Int.random(in: 1 ..< remaining.count, using: &random))
            }
        }
        let pick = remaining[0]
        order.append(contentsOf: remaining)
        entry.order = order
        entry.position = order.count - remaining.count + 1
        entry.last = pick
        displays[display] = entry
        return pick
    }

    func peek(display: String, folder: String, files: [String], random: WallpaperRandom) -> String? {
        var copy = self
        var generator = random
        return copy.next(display: display, folder: folder, files: files, using: &generator)
    }
}

struct WallpaperRuntimeState: Codable, Equatable, Sendable {
    var shuffle = WallpaperShuffle()
    var nextChange: Date?
}
