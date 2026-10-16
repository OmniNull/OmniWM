// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
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
        XCTAssertEqual(Array(ShellProfiles.themes(of: config).prefix(2)), ["native", ShellWallpaperPalette.themeName])

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
}
