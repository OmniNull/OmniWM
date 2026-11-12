// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ImageIO
@testable import OmniWM
import os
import XCTest

@MainActor
final class ShellWallpaperPaletteTests: XCTestCase {
    static func image(_ stripes: [(color: UInt32, weight: Int)]) -> CGImage {
        let width = 320
        let height = 180
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let total = stripes.reduce(0) { $0 + $1.weight }
        var y = 0
        for stripe in stripes {
            let rows = height * stripe.weight / total
            context.setFillColor(CGColor(
                srgbRed: CGFloat((stripe.color >> 16) & 0xFF) / 255,
                green: CGFloat((stripe.color >> 8) & 0xFF) / 255,
                blue: CGFloat(stripe.color & 0xFF) / 255,
                alpha: 1
            ))
            context.fill(CGRect(x: 0, y: y, width: width, height: rows))
            y += rows
        }
        return context.makeImage()!
    }

    static let wallpapers: [(name: String, pixels: [UInt32])] = [
        ("sky", ShellWallpaperPalette.pixels(of: image([(0x1E88E5, 5), (0x90CAF9, 3), (0xFFFFFF, 2)]))),
        ("sunset", ShellWallpaperPalette.pixels(of: image([(0xFF7043, 4), (0x8E24AA, 3), (0x212121, 3)]))),
        ("forest", ShellWallpaperPalette.pixels(of: image([(0x2E7D32, 6), (0x795548, 3), (0xC5E1A5, 1)])))
    ]

    private static let grey = ShellWallpaperPalette.pixels(of: image([(0x6E6E6E, 1), (0xBDBDBD, 1)]))

    private func colors(_ text: String, _ appearance: String) -> [String: UInt32] {
        var colors: [String: UInt32] = [:]
        var section = ""
        for line in text.split(separator: "\n") {
            if line.hasPrefix("[") {
                section = String(line.dropFirst().dropLast())
            } else if section == appearance, let equals = line.firstIndex(of: "=") {
                let name = line[..<equals].trimmingCharacters(in: .whitespaces)
                let hex = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces.union(["\"", "#"]))
                colors[name] = UInt32(hex, radix: 16)
            }
        }
        return colors
    }

    private func spread(_ color: UInt32) -> Int {
        let channels = [Int((color >> 16) & 0xFF), Int((color >> 8) & 0xFF), Int(color & 0xFF)]
        return channels.max()! - channels.min()!
    }

    func testThePaletteIsDeterministicAndFollowsTheScheme() {
        for wallpaper in Self.wallpapers {
            let tonal = ShellWallpaperPalette.theme(pixels: wallpaper.pixels, scheme: .tonalSpot)
            XCTAssertEqual(tonal, ShellWallpaperPalette.theme(pixels: wallpaper.pixels, scheme: .tonalSpot))
            XCTAssertNotEqual(tonal, ShellWallpaperPalette.theme(pixels: wallpaper.pixels, scheme: .vibrant))
            for appearance in ["light", "dark"] {
                XCTAssertEqual(
                    Set(colors(tonal, appearance).keys),
                    Set(ShellMaterialPalette.roles.keys.map { "\($0)" }),
                    wallpaper.name
                )
            }
        }
        let sky = colors(ShellWallpaperPalette.theme(pixels: Self.wallpapers[0].pixels, scheme: .tonalSpot), "dark")
        let accent = sky["accent"] ?? 0
        XCTAssertGreaterThan(accent & 0xFF, (accent >> 16) & 0xFF)
    }

    func testAGreyWallpaperGivesANeutralPalette() {
        for scheme in ShellWallpaperScheme.allCases {
            let grey = ShellWallpaperPalette.theme(pixels: Self.grey, scheme: scheme)
            for appearance in ["light", "dark"] {
                for (role, color) in colors(grey, appearance) where role != "\(ShellRole.error)" {
                    XCTAssertLessThanOrEqual(spread(color), 2, "\(scheme) \(appearance) \(role)")
                }
            }
        }
        let sky = colors(ShellWallpaperPalette.theme(pixels: Self.wallpapers[0].pixels, scheme: .tonalSpot), "dark")
        XCTAssertGreaterThan(spread(sky["accent"] ?? 0), 40)
    }

    func testThePaletteLoadsAsTheWallpaperThemeAndIsWrittenOnlyWhenItChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("profiles.default.theme = \"wallpaper\"\n".utf8).write(to: root.appendingPathComponent("shell.toml"))
        var problems: [String] = []
        let pending = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems))
        XCTAssertEqual(pending.themeName, ShellWallpaperPalette.themeName)
        XCTAssertEqual(pending.theme, ShellTheme.native)
        XCTAssertEqual(problems, [])

        let url = root.appendingPathComponent("themes/wallpaper.toml")
        let text = ShellWallpaperPalette.theme(pixels: Self.wallpapers[1].pixels, scheme: .tonalSpot)
        XCTAssertTrue(try ShellWallpaperPalette.write(text, to: url))
        let written = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertFalse(try ShellWallpaperPalette.write(text, to: url))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, written)

        let loaded = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems))
        XCTAssertEqual(problems, [])
        XCTAssertEqual(loaded.themeName, ShellWallpaperPalette.themeName)
        let accent = try XCTUnwrap(colors(text, "dark")["accent"])
        XCTAssertEqual(
            loaded.theme.dark[ShellRole.accent.rawValue],
            NSColor(shellHex: "#" + String(format: "%06X", accent))
        )
        XCTAssertEqual(loaded.theme.derivedLight, [])
        XCTAssertEqual(loaded.theme.derivedDark, [])
        XCTAssertTrue(try ShellWallpaperPalette.write(
            ShellWallpaperPalette.theme(pixels: Self.wallpapers[1].pixels, scheme: .expressive),
            to: url
        ))
    }

    func testTheSchemeIsAProfileSettingAndWallpaperIsAlwaysAThemeChoice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = ShellConfig.resolve(shellDirectory: root)
        XCTAssertEqual(config.wallpaperScheme, .tonalSpot)
        let builtIn = ["native", ShellWallpaperPalette.themeName]
        let generic = try ShellStyleFixture.themeFiles(in: ShellStyleFixture.defaults)
            .map { $0.deletingPathExtension().lastPathComponent }
        let themes = ShellProfiles.themes(of: config)
        XCTAssertEqual(Array(themes.prefix(builtIn.count)), builtIn)
        XCTAssertEqual(Set(themes), Set(builtIn + generic))

        XCTAssertTrue(try ShellProfiles.selectTheme(ShellWallpaperPalette.themeName, in: root))
        XCTAssertTrue(try ShellProfiles.selectScheme(.rainbow, in: root))
        XCTAssertFalse(try ShellProfiles.selectScheme(.rainbow, in: root))
        let text = try String(contentsOf: root.appendingPathComponent("shell.toml"), encoding: .utf8)
        XCTAssertTrue(try ShellTOMLText.contains(["profiles", "default", "scheme"], in: text), text)
        var problems: [String] = []
        let selected = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems))
        XCTAssertEqual(selected.themeName, ShellWallpaperPalette.themeName)
        XCTAssertEqual(selected.wallpaperScheme, .rainbow)
        XCTAssertEqual(problems, [])

        try Data("profiles.default.scheme = \"sepia\"\n".utf8).write(to: root.appendingPathComponent("shell.toml"))
        let invalid = try XCTUnwrap(ShellConfig.load(shellDirectory: root, problems: &problems))
        XCTAssertEqual(invalid.wallpaperScheme, .tonalSpot)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("scheme must be one of"), problems[0])
    }

    private final class Wallpaper {
        var image: CGImage
        var reads = 0

        init(_ image: CGImage) {
            self.image = image
        }
    }

    private static let sunset = image([(0xFF7043, 4), (0x8E24AA, 3), (0x212121, 3)])
    private static let forest = image([(0x2E7D32, 6), (0x795548, 3), (0xC5E1A5, 1)])
    private static let sky = image([(0x1E88E5, 5), (0x90CAF9, 3), (0xFFFFFF, 2)])

    private final class StillFile: Sendable {
        private let state: OSAllocatedUnfairLock<(current: ShellWallpaperPalette.StillWallpaper, checks: Int)>

        init(_ wallpaper: ShellWallpaperPalette.StillWallpaper) {
            state = OSAllocatedUnfairLock(initialState: (wallpaper, 0))
        }

        var checks: Int {
            state.withLock { $0.checks }
        }

        func show(_ next: ShellWallpaperPalette.StillWallpaper) {
            state.withLock { $0.current = next }
        }

        func check() -> ShellWallpaperPalette.StillWallpaper {
            state.withLock { state in
                state.checks += 1
                return state.current
            }
        }
    }

    private final class Decoder: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CGImage?
        private var decodes = 0

        init(_ image: CGImage?) {
            self.image = image
        }

        var count: Int {
            lock.withLock { decodes }
        }

        func show(_ next: CGImage?) {
            lock.withLock { image = next }
        }

        func read(_: URL) -> CGImage? {
            lock.withLock {
                decodes += 1
                return image
            }
        }
    }

    private final class SourceBox: Sendable {
        private let state: OSAllocatedUnfairLock<ShellWallpaperPalette.Source>

        init(_ source: ShellWallpaperPalette.Source) {
            state = OSAllocatedUnfairLock(initialState: source)
        }

        var current: ShellWallpaperPalette.Source {
            state.withLock { $0 }
        }

        func show(_ next: ShellWallpaperPalette.Source) {
            state.withLock { $0 = next }
        }
    }

    private final class HeldHops: Sendable {
        private let held = OSAllocatedUnfairLock<[@MainActor @Sendable () -> Void]>(initialState: [])

        func deliver(_ work: @escaping @MainActor @Sendable () -> Void) {
            held.withLock { $0.append(work) }
        }

        @MainActor
        func release() {
            let work = held.withLock { held in
                defer { held.removeAll() }
                return held
            }
            for item in work {
                item()
            }
        }
    }

    private final class Problems {
        var reported: [String] = []
    }

    private func makeWriter(
        into root: URL,
        source: @escaping @Sendable () -> ShellWallpaperPalette.Source,
        read: @escaping @Sendable (URL) -> CGImage? = { _ in nil },
        image: @escaping @MainActor (Bool) -> CGImage? = { _ in nil },
        deliver: @escaping ShellWallpaperPaletteWriter.Deliver = { MainActor.assumeIsolated($0) },
        onFailure: @escaping @MainActor (String) -> Void = { _ in }
    ) -> ShellWallpaperPaletteWriter {
        ShellWallpaperPaletteWriter(
            destination: root.appendingPathComponent("themes/wallpaper.toml"),
            scheme: .tonalSpot,
            source: { source },
            read: read,
            image: image,
            perform: { $0() },
            deliver: deliver,
            onFailure: onFailure
        )
    }

    private func capturing(_ wallpaper: Wallpaper, into root: URL) -> ShellWallpaperPaletteWriter {
        makeWriter(into: root, source: { .capture(aerial: false) }, image: { _ in
            wallpaper.reads += 1
            return wallpaper.image
        })
    }

    private func reading(
        _ file: StillFile,
        decoder: Decoder,
        capture: Wallpaper? = nil,
        problems: Problems? = nil,
        into root: URL
    ) -> ShellWallpaperPaletteWriter {
        makeWriter(
            into: root,
            source: { .still(file.check(), aerial: false) },
            read: { decoder.read($0) },
            image: { _ in
                capture?.reads += 1
                return capture?.image
            },
            onFailure: { problems?.reported.append($0) }
        )
    }

    private func palette(of image: CGImage) -> String {
        ShellWallpaperPalette.theme(pixels: ShellWallpaperPalette.pixels(of: image), scheme: .tonalSpot)
    }

    private static let screen = CGRect(x: 0, y: 0, width: 320, height: 180)

    private func window(_ id: UInt32, level: Int32) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowLayer as String: level,
            kCGWindowBounds as String: Self.screen.dictionaryRepresentation
        ]
    }

    private func writeWallpaper(_ images: [CGImage], to url: URL, type: String) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, type as CFString, images.count, nil
        ))
        for image in images {
            CGImageDestinationAddImage(destination, image, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func desktop(
        _ url: URL,
        provider: String = "com.apple.wallpaper.choice.image",
        shuffle: Any = "$null"
    ) throws -> [String: Any] {
        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["type": "imageFile", "url": ["relative": url.absoluteString]],
            format: .binary,
            options: 0
        )
        let choice: [String: Any] = ["Configuration": configuration, "Files": [Any](), "Provider": provider]
        return ["Desktop": ["Content": ["Choices": [choice], "Shuffle": shuffle]], "Type": "individual"]
    }

    private func store(
        _ url: URL,
        provider: String = "com.apple.wallpaper.choice.image",
        shuffle: Any = "$null"
    ) throws -> Data {
        try store(["Displays": ["MAIN": desktop(url, provider: provider, shuffle: shuffle)]])
    }

    private func store(_ index: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: index, format: .binary, options: 0)
    }

    private func source(
        url: URL?,
        windows: [[String: Any]],
        store: Data?,
        location: (display: String, space: String)? = ("MAIN", "ACTIVE"),
        aerials: URL = ShellWallpaperPalette.aerials
    ) -> ShellWallpaperPalette.Source {
        let probe = ShellWallpaperPalette.stillProbe(
            for: 999, frame: Self.screen, desktopImageURL: { _ in url }, windows: { windows },
            location: { _ in location }
        )
        return ShellWallpaperPalette.source(probe, store: store, aerials: aerials)
    }

    private func paletteImage(
        url: URL,
        windows: [[String: Any]],
        store: Data?,
        capture: CGImage,
        location: (display: String, space: String)? = ("MAIN", "ACTIVE")
    ) -> CGImage? {
        guard case let .still(still, _) = source(url: url, windows: windows, store: store, location: location) else {
            return capture
        }
        return ShellWallpaperPalette.read(still.url)
    }

    func testAStillWallpaperIsReadFromItsFileWhileTheCaptureStillShowsTheOldWallpaper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let still = root.appendingPathComponent("sunset.png")
        try writeWallpaper([Self.sunset], to: still, type: "public.png")
        let system = window(7, level: CGWindowLevelForKey(.desktopWindow) - 1)

        let image = try XCTUnwrap(paletteImage(
            url: still,
            windows: [system],
            store: store(still),
            capture: Self.forest
        ))
        XCTAssertEqual(palette(of: image), palette(of: Self.sunset))
    }

    func testALiveOrDynamicWallpaperIsStillCaptured() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let still = root.appendingPathComponent("sunset.png")
        try writeWallpaper([Self.sunset], to: still, type: "public.png")
        let dynamic = root.appendingPathComponent("dynamic.tiff")
        try writeWallpaper([Self.sunset, Self.sunset], to: dynamic, type: "public.tiff")
        let desktop = CGWindowLevelForKey(.desktopWindow)
        let system = window(7, level: desktop - 1)
        let live = window(8, level: desktop + 1)
        let cases: [(name: String, url: URL, windows: [[String: Any]], store: Data?)] = try [
            ("a live wallpaper app above the desktop", still, [live, system], store(still)),
            ("a dynamic wallpaper with several frames", dynamic, [system], store(dynamic)),
            ("an aerial wallpaper", still, [system], store(still, provider: "com.apple.wallpaper.choice.aerials")),
            ("a shuffled folder", still, [system], store(still, shuffle: ["Interval": 300])),
            ("a store that names another wallpaper", still, [system], store(dynamic)),
            ("an unreadable store", still, [system], nil)
        ]
        for wallpaper in cases {
            let image = try XCTUnwrap(
                paletteImage(
                    url: wallpaper.url,
                    windows: wallpaper.windows,
                    store: wallpaper.store,
                    capture: Self.forest
                ),
                wallpaper.name
            )
            XCTAssertEqual(palette(of: image), palette(of: Self.forest), wallpaper.name)
        }
    }

    func testTheStillWallpaperIsTheOneChosenForTheDisplayInItsActiveSpace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let still = root.appendingPathComponent("sunset.png")
        try writeWallpaper([Self.sunset], to: still, type: "public.png")
        let system = window(7, level: CGWindowLevelForKey(.desktopWindow) - 1)
        let shuffling = try desktop(still, shuffle: ["Interval": 300])
        let showing = try desktop(still)
        let aerial = try desktop(still, provider: "com.apple.wallpaper.choice.aerials")
        let cases: [(name: String, index: [String: Any], location: (display: String, space: String)?, shows: CGImage)] =
            [
                (
                    "the active Space shuffles while another Space shows the same wallpaper",
                    ["Spaces": ["ACTIVE": ["Displays": ["MAIN": shuffling]], "OTHER": ["Displays": ["MAIN": showing]]]],
                    ("MAIN", "ACTIVE"),
                    Self.forest
                ),
                (
                    "the display shuffles while another display shows the same wallpaper",
                    ["Displays": ["MAIN": shuffling, "OTHER": showing]],
                    ("MAIN", "ACTIVE"),
                    Self.forest
                ),
                (
                    "the active Space shows the wallpaper on this display",
                    ["Spaces": ["ACTIVE": ["Displays": ["MAIN": showing]]], "Displays": ["MAIN": aerial]],
                    ("MAIN", "ACTIVE"),
                    Self.sunset
                ),
                (
                    "the active Space shows the wallpaper on every display",
                    ["Spaces": ["ACTIVE": ["Default": showing]], "Displays": ["MAIN": aerial]],
                    ("MAIN", "ACTIVE"),
                    Self.sunset
                ),
                ("the active Space is unknown", ["Displays": ["MAIN": showing]], nil, Self.forest)
            ]
        for wallpaper in cases {
            let image = try XCTUnwrap(
                paletteImage(
                    url: still,
                    windows: [system],
                    store: store(wallpaper.index),
                    capture: Self.forest,
                    location: wallpaper.location
                ),
                wallpaper.name
            )
            XCTAssertEqual(palette(of: image), palette(of: wallpaper.shows), wallpaper.name)
        }
    }

    private func palette(in root: URL) -> String? {
        try? String(contentsOf: root.appendingPathComponent("themes/wallpaper.toml"), encoding: .utf8)
    }

    func testTheRecheckFollowsAWallpaperThatChangesWithoutAStoreEvent() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wallpaper = Wallpaper(Self.sunset)
        let writer = capturing(wallpaper, into: root)
        defer { writer.stop() }
        writer.start()
        XCTAssertEqual(palette(in: root), palette(of: Self.sunset))

        wallpaper.image = Self.forest
        XCTAssertNotEqual(palette(of: Self.forest), palette(of: Self.sunset))
        writer.refreshIfChanged()
        XCTAssertEqual(palette(in: root), palette(of: Self.forest))
    }

    func testTheRecheckLeavesAnUnchangedWallpaperPaletteUnwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wallpaper = Wallpaper(Self.sunset)
        let writer = capturing(wallpaper, into: root)
        defer { writer.stop() }
        writer.start()
        XCTAssertEqual(palette(in: root), palette(of: Self.sunset))
        let edited = "edited by hand"
        try Data(edited.utf8).write(to: root.appendingPathComponent("themes/wallpaper.toml"))

        let reads = wallpaper.reads
        writer.refreshIfChanged()
        XCTAssertEqual(wallpaper.reads, reads + 1)
        XCTAssertEqual(palette(in: root), edited, "an unchanged wallpaper leaves the palette file as it is")
    }

    func testTheRecheckWritesThePaletteAgainAfterAFailedWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let themes = root.appendingPathComponent("themes")
        try Data().write(to: themes)
        let writer = capturing(Wallpaper(Self.sunset), into: root)
        defer { writer.stop() }
        writer.start()
        XCTAssertNil(palette(in: root))

        try FileManager.default.removeItem(at: themes)
        writer.refreshIfChanged()
        XCTAssertEqual(palette(in: root), palette(of: Self.sunset))
    }

    func testARecheckOfAnUnchangedStillWallpaperDoesNotDecodeItAgain() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = StillFile(ShellWallpaperPalette.StillWallpaper(
            url: root.appendingPathComponent("sunset.png"), size: 4096, modified: Date(timeIntervalSince1970: 1000)
        ))
        let decoder = Decoder(Self.sunset)
        let writer = reading(file, decoder: decoder, into: root)
        defer { writer.stop() }
        writer.start()
        XCTAssertEqual(palette(in: root), palette(of: Self.sunset))
        let decodes = decoder.count

        let checks = file.checks
        writer.refreshIfChanged()
        XCTAssertEqual(file.checks, checks + 1)
        XCTAssertEqual(decoder.count, decodes)
    }

    func testARecheckDecodesAStillWallpaperAgainWhenItsModificationDateChanges() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("wallpaper.png")
        let file = StillFile(ShellWallpaperPalette.StillWallpaper(
            url: url, size: 4096, modified: Date(timeIntervalSince1970: 1000)
        ))
        let decoder = Decoder(Self.sunset)
        let writer = reading(file, decoder: decoder, into: root)
        defer { writer.stop() }
        writer.start()
        XCTAssertEqual(palette(in: root), palette(of: Self.sunset))
        let decodes = decoder.count

        decoder.show(Self.forest)
        file.show(ShellWallpaperPalette.StillWallpaper(
            url: url, size: 4096, modified: Date(timeIntervalSince1970: 2000)
        ))
        writer.refreshIfChanged()
        XCTAssertEqual(palette(in: root), palette(of: Self.forest))
        XCTAssertEqual(decoder.count, decodes + 1)
    }

    func testTheRecheckWritesThePaletteAgainAfterItsFileIsDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("themes/wallpaper.toml")
        let file = StillFile(ShellWallpaperPalette.StillWallpaper(
            url: root.appendingPathComponent("sunset.png"), size: 4096, modified: Date(timeIntervalSince1970: 1000)
        ))
        let still = reading(file, decoder: Decoder(Self.sunset), into: root)
        still.start()
        XCTAssertEqual(palette(in: root), palette(of: Self.sunset))
        try FileManager.default.removeItem(at: destination)
        still.refreshIfChanged()
        XCTAssertEqual(
            palette(in: root),
            palette(of: Self.sunset),
            "an unchanged still wallpaper rewrites a deleted palette"
        )
        still.stop()

        let captured = capturing(Wallpaper(Self.forest), into: root)
        defer { captured.stop() }
        captured.start()
        XCTAssertEqual(palette(in: root), palette(of: Self.forest))
        try FileManager.default.removeItem(at: destination)
        captured.refreshIfChanged()
        XCTAssertEqual(
            palette(in: root), palette(of: Self.forest), "an unchanged captured wallpaper rewrites a deleted palette"
        )
    }

    func testAnUnreadableStillWallpaperFallsBackToTheCaptureAndIsReadAgainOnlyOnceItChanges() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("aerials/thumbnails/44166C39.png")
        let file = StillFile(ShellWallpaperPalette.StillWallpaper(
            url: url, size: 4096, modified: Date(timeIntervalSince1970: 1000)
        ))
        let decoder = Decoder(nil)
        let problems = Problems()
        let writer = reading(file, decoder: decoder, capture: Wallpaper(Self.forest), problems: problems, into: root)
        defer { writer.stop() }
        writer.start()
        XCTAssertEqual(
            palette(in: root),
            palette(of: Self.forest),
            "a file that cannot be read falls back to the capture"
        )
        let decodes = decoder.count

        writer.refreshIfChanged()
        XCTAssertEqual(decoder.count, decodes, "the recheck does not read the same unreadable file again")
        XCTAssertEqual(problems.reported, [])

        decoder.show(Self.sunset)
        file.show(ShellWallpaperPalette.StillWallpaper(
            url: url, size: 4096, modified: Date(timeIntervalSince1970: 2000)
        ))
        writer.refreshIfChanged()
        XCTAssertEqual(palette(in: root), palette(of: Self.sunset), "a file that changed is read again")
    }

    func testAnUnreadableStillWallpaperWithoutACaptureKeepsItsColors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sky = palette(of: Self.sky)
        XCTAssertTrue(try ShellWallpaperPalette.write(sky, to: root.appendingPathComponent("themes/wallpaper.toml")))
        let file = StillFile(ShellWallpaperPalette.StillWallpaper(
            url: root.appendingPathComponent("broken.png"), size: 4096, modified: Date(timeIntervalSince1970: 1000)
        ))
        let problems = Problems()
        let writer = reading(file, decoder: Decoder(nil), problems: problems, into: root)
        defer { writer.stop() }
        writer.start()
        XCTAssertEqual(
            problems.reported,
            ["The wallpaper palette keeps its last colors because the wallpaper image is unavailable"]
        )
        XCTAssertEqual(palette(in: root), sky)
    }

    func testTheWriterLooksAtTheWallpaperFileOffTheMainActor() {
        let ranOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let finished = DispatchSemaphore(value: 0)
        ShellWallpaperPaletteWriter.performOnWriterQueue {
            ranOnMain.withLock { $0 = Thread.isMainThread }
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + failureBound), .success)
        XCTAssertEqual(
            ranOnMain.withLock { $0 }, false,
            "the Store read, the image source check and the file stat must not wait on a slow volume on the main actor"
        )
    }

    func testTheRecheckRunsOnlyWhileTheWriterIsStarted() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wallpaper = Wallpaper(Self.sunset)
        let stopped = capturing(wallpaper, into: root)
        XCTAssertFalse(stopped.isRechecking)
        stopped.start()
        XCTAssertTrue(stopped.isRechecking)
        stopped.stop()
        XCTAssertFalse(stopped.isRechecking)
        let reads = wallpaper.reads
        stopped.refreshIfChanged()
        XCTAssertEqual(wallpaper.reads, reads, "a stopped writer does not capture for a late recheck")

        var started: ShellWallpaperPaletteWriter? = capturing(wallpaper, into: root)
        started?.start()
        XCTAssertEqual(started?.isRechecking, true)
        weak let released = started
        started = nil
        XCTAssertNil(released, "a started writer is released with its recheck")
    }

    func testAnOlderCaptureDoesNotOverwriteANewerPalette() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hops = HeldHops()
        let source = SourceBox(.capture(aerial: false))
        let decoder = Decoder(Self.sunset)
        let captured = Wallpaper(Self.forest)
        let writer = makeWriter(
            into: root,
            source: { source.current },
            read: { decoder.read($0) },
            image: { _ in captured.image },
            deliver: { hops.deliver($0) }
        )
        defer { writer.stop() }
        writer.start()
        XCTAssertNil(palette(in: root))

        source.show(.still(ShellWallpaperPalette.StillWallpaper(
            url: root.appendingPathComponent("sunset.png"), size: 4096, modified: Date(timeIntervalSince1970: 1000)
        ), aerial: false))
        writer.refresh()
        XCTAssertEqual(palette(in: root), palette(of: Self.sunset))

        hops.release()
        XCTAssertEqual(
            palette(in: root),
            palette(of: Self.sunset),
            "an older capture does not overwrite a newer palette"
        )
    }

    func testASchemeChangeIsWrittenWhenARecheckOvertakesItsCapture() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hops = HeldHops()
        let wallpaper = Wallpaper(Self.sunset)
        let writer = makeWriter(
            into: root,
            source: { .capture(aerial: false) },
            image: { _ in wallpaper.image },
            deliver: { hops.deliver($0) }
        )
        defer { writer.stop() }
        writer.start()
        hops.release()
        XCTAssertEqual(palette(in: root), palette(of: Self.sunset))
        let monochrome = ShellWallpaperPalette.theme(
            pixels: ShellWallpaperPalette.pixels(of: Self.sunset),
            scheme: .monochrome
        )
        XCTAssertNotEqual(monochrome, palette(of: Self.sunset))

        writer.setScheme(.monochrome)
        writer.refreshIfChanged()
        hops.release()
        XCTAssertEqual(
            palette(in: root),
            monochrome,
            "the newer recheck writes the scheme its overtaken refresh asked for"
        )
    }

    private func aerialStore(_ asset: String) throws -> Data {
        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["assetID": asset], format: .binary, options: 0
        )
        let choice: [String: Any] = [
            "Configuration": configuration, "Files": [Any](), "Provider": "com.apple.wallpaper.choice.aerials"
        ]
        return try store(["Spaces": ["ACTIVE": ["Displays": [
            "MAIN": ["Desktop": ["Content": ["Choices": [choice], "Shuffle": "$null"]], "Type": "individual"]
        ]]]])
    }

    func testAnAerialIsSampledFromItsThumbnailAndNeverFromAStaleWallpaperFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let aerials = root.appendingPathComponent("aerials", isDirectory: true)
        try FileManager.default.createDirectory(
            at: aerials.appendingPathComponent("thumbnails"), withIntermediateDirectories: true
        )
        let stale = root.appendingPathComponent("previous.png")
        try writeWallpaper([Self.forest], to: stale, type: "public.png")
        let thumbnail = aerials.appendingPathComponent("thumbnails/44166C39.png")
        try writeWallpaper([Self.sunset], to: thumbnail, type: "public.png")
        let system = window(7, level: CGWindowLevelForKey(.desktopWindow) - 1)
        let store = try aerialStore("44166C39")

        let found = source(url: stale, windows: [system], store: store, aerials: aerials)
        guard case let .still(still, aerial) = found else {
            return XCTFail("Expected the Aerial's thumbnail, got \(found)")
        }
        XCTAssertTrue(aerial)
        XCTAssertEqual(still.url.standardizedFileURL, thumbnail.standardizedFileURL)
        let image = try XCTUnwrap(ShellWallpaperPalette.read(still.url))
        XCTAssertEqual(palette(of: image), palette(of: Self.sunset))
        XCTAssertEqual(
            ShellWallpaperPalette.desktopChoice(store: store, location: ("MAIN", "ACTIVE"), aerials: aerials),
            .aerial(asset: "44166C39", thumbnail: thumbnail.standardizedFileURL)
        )
    }

    func testAnAerialUnderALiveWallpaperAppIsCapturedInsteadOfReadFromItsThumbnail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let aerials = root.appendingPathComponent("aerials", isDirectory: true)
        try FileManager.default.createDirectory(
            at: aerials.appendingPathComponent("thumbnails"), withIntermediateDirectories: true
        )
        let thumbnail = aerials.appendingPathComponent("thumbnails/44166C39.png")
        try writeWallpaper([Self.sunset], to: thumbnail, type: "public.png")
        let desktop = CGWindowLevelForKey(.desktopWindow)
        let system = window(7, level: desktop - 1)
        let live = window(8, level: desktop + 1)
        let store = try aerialStore("44166C39")
        let shownAlone = source(url: nil, windows: [system], store: store, aerials: aerials)
        guard case let .still(still, _) = shownAlone else {
            return XCTFail("Expected the Aerial's thumbnail, got \(shownAlone)")
        }
        XCTAssertEqual(still.url.standardizedFileURL, thumbnail.standardizedFileURL)
        XCTAssertEqual(
            source(url: nil, windows: [live, system], store: store, aerials: aerials), .capture(aerial: true),
            "a live wallpaper app in front of the Aerial is not its thumbnail"
        )
        let shown = ShellWallpaperPalette.screenImage(
            for: 999, aerial: true, capture: { _ in Self.forest }, fallback: { _ in nil }
        )
        XCTAssertEqual(shown.map(palette(of:)), palette(of: Self.forest))
    }

    func testAnAerialWithoutAThumbnailIsCapturedOrKeepsItsColorsButNeverReadsTheStaleFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let aerials = root.appendingPathComponent("aerials", isDirectory: true)
        let stale = root.appendingPathComponent("previous.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeWallpaper([Self.forest], to: stale, type: "public.png")
        let system = window(7, level: CGWindowLevelForKey(.desktopWindow) - 1)
        let store = try aerialStore("MISSING")
        XCTAssertEqual(source(url: stale, windows: [system], store: store, aerials: aerials), .capture(aerial: true))
        func screen(capture: CGImage?) -> CGImage? {
            ShellWallpaperPalette.screenImage(
                for: 999, aerial: true, capture: { _ in capture }, fallback: { _ in ShellWallpaperPalette.read(stale) }
            )
        }
        XCTAssertEqual(screen(capture: Self.sunset).map(palette(of:)), palette(of: Self.sunset))
        XCTAssertNil(screen(capture: nil), "a failed capture keeps the last colors instead of the stale file")

        let still = root.appendingPathComponent("still.png")
        try writeWallpaper([Self.sky], to: still, type: "public.png")
        let fileStore = try self.store(still, shuffle: ["Interval": 300])
        XCTAssertEqual(
            source(url: still, windows: [system], store: fileStore, aerials: aerials), .capture(aerial: false)
        )
        let other = ShellWallpaperPalette.screenImage(
            for: 999, aerial: false, capture: { _ in nil }, fallback: { _ in ShellWallpaperPalette.read(still) }
        )
        XCTAssertEqual(
            other.map(palette(of:)), ShellWallpaperPalette.read(still).map(palette(of:)),
            "other wallpapers keep their usual fallback"
        )
    }

    func testTheDesktopChoiceNamesTheFileTheAerialOrTheShuffleForTheDisplayAndSpace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let aerials = root.appendingPathComponent("aerials", isDirectory: true)
        let still = root.appendingPathComponent("chosen.png")
        XCTAssertEqual(
            ShellWallpaperPalette.desktopChoice(
                store: try store(still),
                location: ("MAIN", "ACTIVE"),
                aerials: aerials
            ),
            .file(still.standardizedFileURL)
        )
        XCTAssertEqual(
            ShellWallpaperPalette.desktopChoice(
                store: try store(still, shuffle: ["Interval": 300]), location: ("MAIN", "ACTIVE"), aerials: aerials
            ),
            .shuffle
        )
        XCTAssertEqual(
            ShellWallpaperPalette.desktopChoice(
                store: try aerialStore("X"),
                location: ("MAIN", "ACTIVE"),
                aerials: aerials
            ),
            .aerial(asset: "X", thumbnail: nil)
        )
        XCTAssertNil(ShellWallpaperPalette.desktopChoice(store: nil, location: ("MAIN", "ACTIVE"), aerials: aerials))
    }
}
