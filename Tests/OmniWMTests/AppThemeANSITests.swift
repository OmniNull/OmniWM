// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import TOML
import XCTest

final class AppThemeANSITests: XCTestCase {
    private func assertReadable(
        _ ansi: [AppThemeColor],
        on background: AppThemeColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(ansi.count, 16, file: file, line: line)
        for index in 1 ..< 16 {
            XCTAssertGreaterThanOrEqual(
                ansi[index].contrast(background), AppThemeANSI.readableContrast,
                "ansi\(index) \(ansi[index].hex) on \(background.hex)", file: file, line: line
            )
        }
    }

    func testCuratedPalettesStayReadableInLightAndDark() {
        let palette = AppThemeFixtures.palette
        assertReadable(palette.light.ansi, on: AppThemeFixtures.light[.background]!)
        assertReadable(palette.dark.ansi, on: AppThemeFixtures.dark[.background]!)
        XCTAssertEqual(palette.dark.ansi[0], AppThemeFixtures.dark[.surface])
        XCTAssertEqual(palette.dark.ansi[15], AppThemeFixtures.dark[.foreground])
    }

    func testReadableHueSlotsAreDistinct() {
        for scheme in [AppThemeFixtures.palette.light, AppThemeFixtures.palette.dark] {
            let slots = Array(scheme.ansi[1 ... 6]) + Array(scheme.ansi[9 ... 14])
            XCTAssertEqual(Set(slots).count, slots.count, slots.map(\.hex).joined(separator: " "))
        }
    }

    func testHuesKeepTheirMeaning() {
        let dark = AppThemeFixtures.palette.dark.ansi
        XCTAssertGreaterThan(dark[1].red, dark[1].blue)
        XCTAssertGreaterThan(dark[2].green, dark[2].red)
        XCTAssertGreaterThan(dark[4].blue, dark[4].red)
    }

    func testBrightColorsMoveAwayFromTheBackground() {
        let palette = AppThemeFixtures.palette
        for index in 1 ... 6 {
            XCTAssertGreaterThanOrEqual(
                palette.dark.ansi[index + 8].hsl.lightness,
                palette.dark.ansi[index].hsl.lightness
            )
            XCTAssertLessThanOrEqual(
                palette.light.ansi[index + 8].hsl.lightness,
                palette.light.ansi[index].hsl.lightness
            )
        }
    }

    func testLowContrastRolesAreLiftedUntilReadable() {
        let roles = AppThemeFixtures.roles([
            .background: "#202020", .surface: "#252525", .foreground: "#303030", .secondaryForeground: "#282828",
            .mutedForeground: "#222222", .red: "#300000", .green: "#003000", .yellow: "#303000",
            .blue: "#000030", .purple: "#300030", .cyan: "#003030"
        ])
        let ansi = AppThemeANSI.colors(roles: roles, dark: true)
        assertReadable(ansi, on: AppThemeColor(hex: "#202020")!)
        XCTAssertGreaterThan(ansi[1].red, ansi[1].green)
    }

    func testMidGrayBackgroundFallsBackWithoutFailing() {
        for gray in ["#767676", "#777777", "#7a7a7a", "#808080"] {
            let gray = AppThemeColor(hex: gray)!
            let roles: [ShellRole: AppThemeColor] = [
                .background: gray, .surface: gray, .foreground: gray, .secondaryForeground: gray,
                .mutedForeground: gray, .red: gray, .green: gray, .yellow: gray, .blue: gray, .purple: gray, .cyan: gray
            ]
            for dark in [false, true] {
                assertReadable(AppThemeANSI.colors(roles: roles, dark: dark), on: gray)
            }
        }
    }

    func testMidGrayBackgroundWithAVividAccentStillFallsBackWithoutFailing() {
        let gray = AppThemeColor(hex: "#777777")!
        let roles: [ShellRole: AppThemeColor] = [
            .background: gray, .surface: gray, .foreground: gray, .accent: AppThemeColor(hex: "#00C2A8")!,
            .red: gray, .green: gray, .yellow: gray, .blue: gray, .purple: gray, .cyan: gray
        ]
        for dark in [false, true] {
            assertReadable(AppThemeANSI.colors(roles: roles, dark: dark), on: gray)
        }
    }

    private func hueDistance(_ first: Double, _ second: Double) -> Double {
        let difference = abs(first - second).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }

    @MainActor
    private func wallpaperPalette(
        _ pixel: UInt32,
        terminalColors: AppThemeTerminalColors = .palette
    ) throws -> AppThemePalette {
        let text = ShellWallpaperPalette.theme(pixels: Array(repeating: pixel, count: 64), scheme: .tonalSpot)
        let toml = try TOMLDecoder().decode([String: TOMLNode].self, from: Data(text.utf8))
        var problems: [String] = []
        let theme = ShellTheme(toml: toml, name: ShellWallpaperPalette.themeName, problems: &problems)
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "; "))
        return AppThemePalette(theme: theme, terminalColors: terminalColors)
    }

    @MainActor
    func testWallpaperPalettesTintTerminalHuesTowardTheAccent() throws {
        let system = AppThemePalette(theme: .native)
        for pixel: UInt32 in [0xFF2A_9D8F, 0xFF8E_3B9F, 0xFFD9_8C1F] {
            let wallpaper = try wallpaperPalette(pixel, terminalColors: .standard)
            for (tinted, plain) in [(wallpaper.light, system.light), (wallpaper.dark, system.dark)] {
                let background = try XCTUnwrap(tinted.roles[.background])
                let accent = try XCTUnwrap(tinted.roles[.accent]).hsl.hue
                assertReadable(tinted.ansi, on: background)
                let slots = Array(tinted.ansi[1 ... 6]) + Array(tinted.ansi[9 ... 14])
                XCTAssertEqual(Set(slots).count, slots.count, slots.map(\.hex).joined(separator: " "))
                for (offset, role) in AppThemeANSI.hueRoles.enumerated() {
                    let systemHue = try XCTUnwrap(plain.roles[role]).hsl.hue
                    let hue = tinted.ansi[offset + 1].hsl.hue
                    XCTAssertLessThanOrEqual(hueDistance(hue, systemHue), 35, "\(role) lost its hue")
                    guard hueDistance(systemHue, accent) > 8 else { continue }
                    XCTAssertLessThan(
                        hueDistance(hue, accent), hueDistance(systemHue, accent) - 3,
                        "\(role) \(tinted.ansi[offset + 1].hex) did not move toward the accent hue \(Int(accent))"
                    )
                }
            }
        }
    }

    @MainActor
    func testFollowingTheWallpaperPaletteUsesNoctaliasAccentMapping() throws {
        for pixel: UInt32 in [0xFF2A_9D8F, 0xFF8E_3B9F, 0xFFD9_8C1F, 0xFF3A_5BD9] {
            let wallpaper = try wallpaperPalette(pixel)
            for scheme in [wallpaper.light, wallpaper.dark] {
                let background = try XCTUnwrap(scheme.roles[.background])
                assertReadable(scheme.ansi, on: background)
                let sources: [ShellRole] = [
                    .error,
                    .accent,
                    .secondaryAccent,
                    .tertiaryAccent,
                    .accent,
                    .secondaryAccent
                ]
                for (offset, role) in sources.enumerated() {
                    let source = try XCTUnwrap(scheme.roles[role])
                    for slot in [offset + 1, offset + 9] where source.hsl.saturation > 0.12 {
                        XCTAssertLessThanOrEqual(
                            hueDistance(scheme.ansi[slot].hsl.hue, source.hsl.hue), 25,
                            "ansi\(slot) \(scheme.ansi[slot].hex) should follow \(role) \(source.hex)"
                        )
                    }
                }
                let slots = Array(scheme.ansi[1 ... 6]) + Array(scheme.ansi[9 ... 14])
                XCTAssertEqual(Set(slots).count, slots.count, slots.map(\.hex).joined(separator: " "))
            }
        }
    }

    func testThemesWithTheirOwnHuesKeepThemUntinted() {
        let palette = AppThemeFixtures.palette
        for (scheme, roles) in [(palette.light, AppThemeFixtures.light), (palette.dark, AppThemeFixtures.dark)] {
            for (offset, role) in AppThemeANSI.hueRoles.enumerated() {
                let source = roles[role]!
                XCTAssertLessThanOrEqual(
                    hueDistance(scheme.ansi[offset + 1].hsl.hue, source.hsl.hue), 2.5,
                    "\(role) \(scheme.ansi[offset + 1].hex) moved from \(source.hex)"
                )
            }
        }
        let standard = AppThemePalette(
            light: AppThemeFixtures.light,
            dark: AppThemeFixtures.dark,
            terminalColors: .standard
        )
        XCTAssertNotEqual(standard.dark.ansi, palette.dark.ansi)
    }

    func testHarmonizingKeepsTheHueOrder() {
        let accent = AppThemeColor(hex: "#2A9D8F")!
        let hues = stride(from: 0.0, to: 360, by: 15).map { AppThemeColor(hsl: AppThemeHSL(
            hue: $0,
            saturation: 0.8,
            lightness: 0.5
        )) }
        let shifted = hues.map { AppThemeANSI.harmonized($0, toward: accent).hsl.hue }
        let accentHue = accent.hsl.hue
        func unwrap(_ hue: Double) -> Double {
            (hue - accentHue + 540).truncatingRemainder(dividingBy: 360) - 180
        }
        let ordered = zip(hues, shifted).map { (unwrap($0.0.hsl.hue), unwrap($0.1)) }.sorted { $0.0 < $1.0 }
        for (before, after) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThanOrEqual(before.1, after.1 + 1)
        }
        for (original, moved) in zip(hues, shifted) {
            XCTAssertLessThanOrEqual(hueDistance(original.hsl.hue, moved), 15.5)
        }
    }

    func testMissingRolesStillProduceSixteenReadableColors() {
        assertReadable(AppThemeANSI.colors(roles: [:], dark: true), on: .black)
        assertReadable(AppThemeANSI.colors(roles: [:], dark: false), on: .white)
    }

    func testTranslucentRolesAreUsedOpaque() {
        var roles = AppThemeFixtures.dark
        roles[.red] = AppThemeColor(hex: "#F38BA820")
        let ansi = AppThemeANSI.colors(roles: roles, dark: true)
        XCTAssertEqual(ansi[1].alpha, 1)
    }

    func testHexAndHSLRoundTrip() throws {
        for hex in ["#000000", "#ffffff", "#d20f39", "#40a02b", "#1e66f5", "#89dceb", "#7f7f7f"] {
            let color = try XCTUnwrap(AppThemeColor(hex: hex))
            XCTAssertEqual(color.hex, hex)
            XCTAssertEqual(AppThemeColor(hsl: color.hsl).hex, hex)
        }
        XCTAssertNil(AppThemeColor(hex: "#12345"))
        XCTAssertNil(AppThemeColor(hex: "123456"))
        XCTAssertNil(AppThemeColor(hex: "#+12345"))
    }

    @MainActor
    func testNativeAndBundledThemesResolveReadableTerminalColors() throws {
        let palette = AppThemePalette(theme: .native)
        for scheme in [palette.light, palette.dark] {
            let background = try XCTUnwrap(scheme.roles[.background])
            assertReadable(scheme.ansi, on: background.opaque)
        }
        XCTAssertNotEqual(palette.light.roles[.background], palette.dark.roles[.background])
    }
}
