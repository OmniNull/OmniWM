// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ImageIO
@testable import OmniWM
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

    private func rechecking(_ wallpaper: Wallpaper, into root: URL) -> ShellWallpaperPaletteWriter {
        ShellWallpaperPaletteWriter(
            destination: root.appendingPathComponent("themes/wallpaper.toml"),
            scheme: .tonalSpot,
            recheckInterval: 0.02,
            still: { nil },
            image: {
                wallpaper.reads += 1
                return wallpaper.image
            },
            onFailure: { _ in }
        )
    }

    private final class StillFile {
        var wallpaper: ShellWallpaperPalette.StillWallpaper
        var checks = 0

        init(_ wallpaper: ShellWallpaperPalette.StillWallpaper) {
            self.wallpaper = wallpaper
        }
    }

    private final class Decoder: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CGImage
        private var decodes = 0

        init(_ image: CGImage) {
            self.image = image
        }

        var count: Int {
            lock.withLock { decodes }
        }

        func show(_ next: CGImage) {
            lock.withLock { image = next }
        }

        func read(_: URL) -> CGImage? {
            lock.withLock {
                decodes += 1
                return image
            }
        }
    }

    private func rechecking(_ file: StillFile, decoder: Decoder, into root: URL) -> ShellWallpaperPaletteWriter {
        ShellWallpaperPaletteWriter(
            destination: root.appendingPathComponent("themes/wallpaper.toml"),
            scheme: .tonalSpot,
            recheckInterval: 0.02,
            still: {
                file.checks += 1
                return file.wallpaper
            },
            read: { decoder.read($0) },
            image: { nil },
            onFailure: { _ in }
        )
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
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

    private func paletteImage(
        url: URL,
        windows: [[String: Any]],
        store: Data?,
        capture: CGImage,
        location: (display: String, space: String)? = ("MAIN", "ACTIVE")
    ) -> CGImage? {
        let still = ShellWallpaperPalette.stillWallpaper(
            for: 999, frame: Self.screen, desktopImageURL: { _ in url }, windows: { windows }, store: { store },
            location: { _ in location }
        )
        return still.map { ShellWallpaperPalette.read($0.url) } ?? capture
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

    func testTheRecheckFollowsAWallpaperThatChangesWithoutAStoreEvent() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wallpaper = Wallpaper(Self.sunset)
        let writer = rechecking(wallpaper, into: root)
        defer { writer.stop() }
        writer.start()
        let sunset = palette(of: Self.sunset)
        let wroteSunset = await eventually { palette(in: root) == sunset }
        XCTAssertTrue(wroteSunset)

        wallpaper.image = Self.forest
        let forest = palette(of: Self.forest)
        XCTAssertNotEqual(forest, sunset)
        let followedTheShuffle = await eventually { palette(in: root) == forest }
        XCTAssertTrue(followedTheShuffle)
    }

    func testTheRecheckLeavesAnUnchangedWallpaperPaletteUnwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wallpaper = Wallpaper(Self.sunset)
        let writer = rechecking(wallpaper, into: root)
        defer { writer.stop() }
        writer.start()
        let sunset = palette(of: Self.sunset)
        let written = await eventually { palette(in: root) == sunset }
        XCTAssertTrue(written)
        let path = root.appendingPathComponent("themes/wallpaper.toml").path
        let modified = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date

        let reads = wallpaper.reads
        let rechecked = await eventually { wallpaper.reads >= reads + 3 }
        XCTAssertTrue(rechecked)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date, modified)
        XCTAssertEqual(palette(in: root), sunset)
    }

    func testTheRecheckWritesThePaletteAgainAfterAFailedWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let themes = root.appendingPathComponent("themes")
        try Data().write(to: themes)
        let wallpaper = Wallpaper(Self.sunset)
        let writer = rechecking(wallpaper, into: root)
        defer { writer.stop() }
        writer.start()
        let reads = wallpaper.reads
        let rechecked = await eventually { wallpaper.reads >= reads + 3 }
        XCTAssertTrue(rechecked)
        XCTAssertNil(palette(in: root))

        try FileManager.default.removeItem(at: themes)
        let sunset = palette(of: Self.sunset)
        let retried = await eventually { palette(in: root) == sunset }
        XCTAssertTrue(retried)
    }

    func testARecheckOfAnUnchangedStillWallpaperDoesNotDecodeItAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = StillFile(ShellWallpaperPalette.StillWallpaper(
            url: root.appendingPathComponent("sunset.png"), size: 4096, modified: Date(timeIntervalSince1970: 1000)
        ))
        let decoder = Decoder(Self.sunset)
        let writer = rechecking(file, decoder: decoder, into: root)
        defer { writer.stop() }
        writer.start()
        let sunset = palette(of: Self.sunset)
        let written = await eventually { palette(in: root) == sunset }
        XCTAssertTrue(written)
        var checks = file.checks
        let settled = await eventually { file.checks >= checks + 3 }
        XCTAssertTrue(settled)

        let decodes = decoder.count
        checks = file.checks
        let rechecked = await eventually { file.checks >= checks + 5 }
        XCTAssertTrue(rechecked)
        XCTAssertEqual(decoder.count, decodes)
        XCTAssertEqual(decodes, 1)
    }

    func testARecheckDecodesAStillWallpaperAgainWhenItsModificationDateChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("wallpaper.png")
        let file = StillFile(ShellWallpaperPalette.StillWallpaper(
            url: url, size: 4096, modified: Date(timeIntervalSince1970: 1000)
        ))
        let decoder = Decoder(Self.sunset)
        let writer = rechecking(file, decoder: decoder, into: root)
        defer { writer.stop() }
        writer.start()
        let sunset = palette(of: Self.sunset)
        let written = await eventually { palette(in: root) == sunset }
        XCTAssertTrue(written)

        let decodes = decoder.count
        decoder.show(Self.forest)
        file.wallpaper = ShellWallpaperPalette.StillWallpaper(
            url: url, size: 4096, modified: Date(timeIntervalSince1970: 2000)
        )
        let forest = palette(of: Self.forest)
        let followed = await eventually { palette(in: root) == forest }
        XCTAssertTrue(followed)
        XCTAssertGreaterThan(decoder.count, decodes)
    }

    func testTheRecheckStopsWhenTheWriterIsStoppedOrReleased() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wallpaper = Wallpaper(Self.sunset)
        let stopped = rechecking(wallpaper, into: root)
        stopped.start()
        var reads = wallpaper.reads
        let ticking = await eventually { wallpaper.reads >= reads + 2 }
        XCTAssertTrue(ticking)
        stopped.stop()
        reads = wallpaper.reads
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(wallpaper.reads, reads)

        var released: ShellWallpaperPaletteWriter? = rechecking(wallpaper, into: root)
        released?.start()
        reads = wallpaper.reads
        let restarted = await eventually { wallpaper.reads >= reads + 2 }
        XCTAssertTrue(restarted)
        released = nil
        reads = wallpaper.reads
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(wallpaper.reads, reads)
    }
}
