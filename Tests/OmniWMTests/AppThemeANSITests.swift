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
        XCTAssertEqual(ansi.count, AppThemeANSI.colorCount, file: file, line: line)
        for index in 1 ..< AppThemeANSI.colorCount {
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
            let slots = Array(scheme.ansi[AppThemeANSI.normalHueSlots]) +
                Array(scheme.ansi[AppThemeANSI.brightHueSlots])
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
        for (normal, bright) in zip(AppThemeANSI.normalHueSlots, AppThemeANSI.brightHueSlots) {
            XCTAssertGreaterThanOrEqual(
                palette.dark.ansi[bright].hsl.lightness,
                palette.dark.ansi[normal].hsl.lightness
            )
            XCTAssertLessThanOrEqual(
                palette.light.ansi[bright].hsl.lightness,
                palette.light.ansi[normal].hsl.lightness
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

    private let fullTurn = 360.0
    private let hueSectors = 6.0

    private var halfTurn: Double {
        fullTurn / 2
    }

    private func hueDistance(_ first: Double, _ second: Double) -> Double {
        let difference = abs(first - second).truncatingRemainder(dividingBy: fullTurn)
        return min(difference, fullTurn - difference)
    }

    private func signedTurn(from hue: Double, to target: Double) -> Double {
        (target - hue + fullTurn + halfTurn).truncatingRemainder(dividingBy: fullTurn) - halfTurn
    }

    private func hueRounding(_ colors: AppThemeColor...) -> Double {
        let step = 1 / Double(UInt8.max)
        let degreesPerSector = fullTurn / hueSectors
        return colors.reduce(0) { total, color in
            let channels = [color.red, color.green, color.blue]
            let chroma = Double((channels.max() ?? 0) - (channels.min() ?? 0)) * step
            return total + (chroma > step ? 2 * degreesPerSector * step / (chroma - step) : halfTurn)
        }
    }

    private func tintedHue(_ hue: Double, toward accent: Double) -> Double {
        let difference = signedTurn(from: hue, to: accent)
        return hue + min(max(difference / 2, -AppThemeANSI.maximumHueShift), AppThemeANSI.maximumHueShift)
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
                let slots = Array(tinted.ansi[AppThemeANSI.normalHueSlots]) +
                    Array(tinted.ansi[AppThemeANSI.brightHueSlots])
                XCTAssertEqual(Set(slots).count, slots.count, slots.map(\.hex).joined(separator: " "))
                for (offset, role) in AppThemeANSI.hueRoles.enumerated() {
                    let system = try XCTUnwrap(plain.roles[role])
                    let slot = tinted.ansi[AppThemeANSI.normalHueSlots.lowerBound + offset]
                    XCTAssertLessThanOrEqual(
                        hueDistance(slot.hsl.hue, tintedHue(system.hsl.hue, toward: accent)),
                        hueRounding(system, slot),
                        "\(role) \(slot.hex) should turn from \(system.hex) toward the accent hue \(accent)"
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
                    var dimmed = source.hsl
                    dimmed.lightness = AppThemeANSI.fixedDimLightness
                    for slot in [
                        AppThemeANSI.normalHueSlots.lowerBound + offset,
                        AppThemeANSI.brightHueSlots.lowerBound + offset
                    ] {
                        let color = scheme.ansi[slot]
                        XCTAssertLessThanOrEqual(
                            hueDistance(color.hsl.hue, source.hsl.hue),
                            AppThemeANSI.maximumHueNudge + hueRounding(source, AppThemeColor(hsl: dimmed), color),
                            "ansi\(slot) \(color.hex) should follow \(role) \(source.hex)"
                        )
                    }
                }
                let slots = Array(scheme.ansi[AppThemeANSI.normalHueSlots]) +
                    Array(scheme.ansi[AppThemeANSI.brightHueSlots])
                XCTAssertEqual(Set(slots).count, slots.count, slots.map(\.hex).joined(separator: " "))
            }
        }
    }

    func testThemesWithTheirOwnHuesKeepThemUntinted() {
        let palette = AppThemeFixtures.palette
        for (scheme, roles) in [(palette.light, AppThemeFixtures.light), (palette.dark, AppThemeFixtures.dark)] {
            for (offset, role) in AppThemeANSI.hueRoles.enumerated() {
                let source = roles[role]!
                let slot = scheme.ansi[AppThemeANSI.normalHueSlots.lowerBound + offset]
                XCTAssertLessThanOrEqual(
                    hueDistance(slot.hsl.hue, source.hsl.hue), hueRounding(source, slot),
                    "\(role) \(slot.hex) moved from \(source.hex)"
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
        let samples = 24.0
        let hues = stride(from: 0.0, to: fullTurn, by: fullTurn / samples).map { AppThemeColor(hsl: AppThemeHSL(
            hue: $0,
            saturation: 0.8,
            lightness: 0.5
        )) }
        let moved = hues.map { AppThemeANSI.harmonized($0, toward: accent) }
        let accentHue = accent.hsl.hue
        func unwrap(_ hue: Double) -> Double {
            signedTurn(from: accentHue, to: hue)
        }
        let ordered = zip(hues, moved).map { (unwrap($0.0.hsl.hue), unwrap($0.1.hsl.hue), $0.1) }
            .sorted { $0.0 < $1.0 }
        for (before, after) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThanOrEqual(before.1, after.1 + hueRounding(before.2, after.2))
        }
        for (original, shifted) in zip(hues, moved) {
            XCTAssertLessThanOrEqual(
                hueDistance(original.hsl.hue, shifted.hsl.hue),
                AppThemeANSI.maximumHueShift + hueRounding(shifted)
            )
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
