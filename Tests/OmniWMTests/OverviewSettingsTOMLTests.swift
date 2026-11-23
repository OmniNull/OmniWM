// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class OverviewSettingsTOMLTests: XCTestCase {
    func testDefaultsMatchOverviewContract() {
        let defaults = SettingsExport.defaults()

        XCTAssertEqual(defaults.overview.enabled, true)
        XCTAssertEqual(defaults.overview.zoom, 1.0)
        XCTAssertEqual(defaults.overview.invertScrollDirection, false)
        XCTAssertEqual(defaults.overview.mouseScrollSpeed, 1)
        XCTAssertNil(defaults.overview.mouseButton)
        XCTAssertEqual(defaults.overview.backdrop, color(0.05, 0.05, 0.08, 0))
        XCTAssertEqual(defaults.overview.matchFocusBorder, true)
        XCTAssertEqual(defaults.overview.windowBorders.normal, color(0.3, 0.3, 0.35, 0.5))
        XCTAssertEqual(defaults.overview.windowBorders.hovered, color(0.4, 0.6, 1.0, 1.0))
        XCTAssertEqual(defaults.overview.windowBorders.selected, color(0.3, 0.8, 0.4, 1.0))
    }

    func testRoundTripsCanonicalOverviewTables() throws {
        var export = SettingsExport.defaults()
        export.overview.enabled = false
        export.overview.zoom = 1.25
        export.overview.invertScrollDirection = true
        export.overview.mouseScrollSpeed = 1.75
        export.overview.mouseButton = 4
        export.overview.backdrop = color(0.1, 0.2, 0.3, 0.4)
        export.overview.windowBorders.normal = color(0.2, 0.3, 0.4, 0.5)
        export.overview.windowBorders.hovered = color(0.3, 0.4, 0.5, 0.6)
        export.overview.windowBorders.selected = color(0.4, 0.5, 0.6, 0.7)
        export.overview.matchFocusBorder = false

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsTOMLCodec.decode(data)

        XCTAssertTrue(toml.contains("[overview]"))
        XCTAssertTrue(toml.contains("enabled = false"))
        XCTAssertTrue(toml.contains("[overview.backdrop]"))
        XCTAssertTrue(toml.contains("[overview.windowBorders.normal]"))
        XCTAssertTrue(toml.contains("[overview.windowBorders.hovered]"))
        XCTAssertTrue(toml.contains("[overview.windowBorders.selected]"))
        XCTAssertEqual(decoded.overview.zoom, export.overview.zoom)
        XCTAssertEqual(decoded.overview.enabled, false)
        XCTAssertEqual(decoded.overview.invertScrollDirection, true)
        XCTAssertEqual(decoded.overview.mouseScrollSpeed, 1.75)
        XCTAssertEqual(decoded.overview.mouseButton, 4)
        XCTAssertEqual(decoded.overview.backdrop, export.overview.backdrop)
        XCTAssertEqual(decoded.overview.windowBorders.normal, export.overview.windowBorders.normal)
        XCTAssertEqual(decoded.overview.windowBorders.hovered, export.overview.windowBorders.hovered)
        XCTAssertEqual(decoded.overview.windowBorders.selected, export.overview.windowBorders.selected)
        XCTAssertEqual(decoded.overview.matchFocusBorder, false)
    }

    @MainActor
    func testAppearanceFollowsFocusBorderUnlessDetached() {
        let settings = makeSettingsStore()
        settings.borders.enabled = true
        settings.borders.width = 9
        settings.borders.color = SettingsColor(red: 0.9, green: 0.1, blue: 0.2, alpha: 1)
        settings.borders.darkColor = SettingsColor(red: 0.1, green: 0.9, blue: 0.2, alpha: 1)
        settings.borders.gradient = BorderGradient(
            enabled: true,
            start: SettingsColor(red: 1, green: 0, blue: 0, alpha: 1),
            end: SettingsColor(red: 0, green: 0, blue: 1, alpha: 1),
            direction: .topLeftToBottomRight,
            dark: nil
        )
        let darkStart = SettingsColor(red: 0.6, green: 0.2, blue: 0.8, alpha: 1)
        let darkGlow = SettingsColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1)
        settings.borders.gradient?.dark = BorderGradientColors(start: darkStart, end: nil)
        settings.borders.glow = BorderGlow(enabled: true, radius: 12, opacity: 0.6, darkColor: darkGlow)
        settings.overview.selectedBorderColor = SettingsColor(red: 0.3, green: 0.8, blue: 0.4, alpha: 1)

        settings.overview.matchFocusBorder = true
        XCTAssertEqual(OverviewAppearance(settings: settings, isDark: false).selectedBorder, settings.borders.color)
        XCTAssertEqual(OverviewAppearance(settings: settings, isDark: true).selectedBorder, settings.borders.darkColor)
        XCTAssertEqual(OverviewAppearance(settings: settings, isDark: false).focusBorder?.gradient?.enabled, true)

        let matched = OverviewAppearance(settings: settings, isDark: true)
        XCTAssertEqual(matched.focusBorder?.enabled, true)
        XCTAssertEqual(matched.focusBorder?.width, 9)
        XCTAssertEqual(matched.focusBorder?.gradient?.start, darkStart)
        XCTAssertEqual(matched.focusBorder?.gradient?.end, settings.borders.gradient?.end)
        XCTAssertNil(matched.focusBorder?.gradient?.dark)
        XCTAssertEqual(matched.focusBorder?.glow?.color, darkGlow)
        XCTAssertNil(matched.focusBorder?.glow?.darkColor)
        settings.borders.enabled = false
        XCTAssertEqual(OverviewAppearance(settings: settings, isDark: false).focusBorder?.enabled, false)

        settings.overview.matchFocusBorder = false
        let detached = OverviewAppearance(settings: settings, isDark: true)
        XCTAssertEqual(detached.selectedBorder, settings.overview.selectedBorderColor)
        XCTAssertNil(detached.focusBorder)
    }

    func testMissingMatchFocusBorderDefaultsToMatching() throws {
        var export = SettingsExport.defaults()
        export.overview.matchFocusBorder = nil
        let toml = String(decoding: try SettingsTOMLCodec.encode(export), as: UTF8.self)
        XCTAssertFalse(toml.contains("matchFocusBorder"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(toml.utf8)).overview.matchFocusBorder, true)
    }

    func testMissingEnabledDefaultsToOn() throws {
        var export = SettingsExport.defaults()
        export.overview.enabled = nil
        let toml = String(decoding: try SettingsTOMLCodec.encode(export), as: UTF8.self)
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(toml.utf8)).overview.enabled, true)
    }

    func testMalformedOverviewTypesRejectDecode() throws {
        let defaults = String(
            decoding: try SettingsTOMLCodec.encode(SettingsExport.defaults()),
            as: UTF8.self
        )
        let malformed = [
            replacingValue(in: defaults, table: "overview", key: "zoom", with: "\"large\""),
            replacingValue(in: defaults, table: "overview.backdrop", key: "red", with: "\"dark\""),
            replacingValue(
                in: defaults,
                table: "overview.windowBorders.selected",
                key: "alpha",
                with: "true"
            )
        ]

        for toml in malformed {
            XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(toml.utf8)))
        }
    }

    @MainActor
    func testApplyExportClampsZoomAndColorComponents() {
        let defaults = SettingsExport.defaults()
        var export = defaults
        export.overview.zoom = .nan
        export.overview.backdrop = color(-1, 2, .nan, .infinity)
        export.overview.windowBorders.normal = color(.infinity, -.infinity, 0.25, 0.75)
        export.overview.windowBorders.hovered = color(1.5, -0.5, .nan, 0.4)
        export.overview.windowBorders.selected = color(0.2, .nan, 2, -1)

        let settings = makeSettingsStore()
        settings.applyExport(export)

        XCTAssertEqual(settings.overview.zoom, defaults.overview.zoom)
        XCTAssertEqual(settings.overview.backdropColor, color(0, 1, defaults.overview.backdrop.blue, 0))
        XCTAssertEqual(
            settings.overview.normalBorderColor,
            color(
                defaults.overview.windowBorders.normal.red,
                defaults.overview.windowBorders.normal.green,
                0.25,
                0.75
            )
        )
        XCTAssertEqual(
            settings.overview.hoveredBorderColor,
            color(1, 0, defaults.overview.windowBorders.hovered.blue, 0.4)
        )
        XCTAssertEqual(
            settings.overview.selectedBorderColor,
            color(0.2, defaults.overview.windowBorders.selected.green, 1, 0)
        )
    }

    @MainActor
    func testApplyExportClampsFiniteZoomBoundsAndExportsNormalizedValues() {
        let settings = makeSettingsStore()
        var export = SettingsExport.defaults()

        export.overview.zoom = 0.25
        settings.applyExport(export)
        XCTAssertEqual(settings.overview.zoom, 0.5)

        export.overview.zoom = 2
        settings.applyExport(export)
        XCTAssertEqual(settings.overview.zoom, 1.5)
        XCTAssertEqual(settings.toExport().overview.zoom, 1.5)
    }

    @MainActor
    func testAutosavePersistsEveryOverviewSetting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewAutosaveTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let persistence = SettingsFilePersistence(
            directory: root.appendingPathComponent("config", isDirectory: true),
            startWatching: false,
            deferSaves: false
        )
        let settings = SettingsStore(
            persistence: persistence,
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: true
        )

        settings.overview.zoom = 1.25
        settings.overview.invertScrollDirection = true
        settings.overview.mouseScrollSpeed = 0.05
        try settings.setOverviewMouseButton(2)
        settings.overview.backdropColor = color(0.1, 0.2, 0.3, 0.4)
        settings.overview.normalBorderColor = color(0.2, 0.3, 0.4, 0.5)
        settings.overview.hoveredBorderColor = color(0.3, 0.4, 0.5, 0.6)
        settings.overview.selectedBorderColor = color(0.4, 0.5, 0.6, 0.7)

        let persisted = try SettingsLuauDocument(Data(contentsOf: persistence.fileURL)).export
        XCTAssertEqual(persisted.overview.zoom, settings.overview.zoom)
        XCTAssertEqual(persisted.overview.invertScrollDirection, true)
        XCTAssertEqual(persisted.overview.mouseScrollSpeed, 0.05)
        XCTAssertEqual(persisted.overview.mouseButton, 2)
        XCTAssertEqual(persisted.overview.backdrop, settings.overview.backdropColor)
        XCTAssertEqual(persisted.overview.windowBorders.normal, settings.overview.normalBorderColor)
        XCTAssertEqual(persisted.overview.windowBorders.hovered, settings.overview.hoveredBorderColor)
        XCTAssertEqual(persisted.overview.windowBorders.selected, settings.overview.selectedBorderColor)
    }

    @MainActor
    func testWheelSpeedLoadsWithinSupportedRange() {
        let settings = makeSettingsStore()
        for (value, expected) in [(0.0, 0.05), (0.05, 0.05), (2.0, 2.0), (3.0, 2.0), (.nan, 1.0)] {
            var export = SettingsExport.defaults()
            export.overview.mouseScrollSpeed = value
            settings.applyExport(export)
            XCTAssertEqual(settings.overview.mouseScrollSpeed, expected)
            XCTAssertEqual(settings.toExport().overview.mouseScrollSpeed, expected)
        }
    }

    private func color(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) -> SettingsColor {
        SettingsColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private func replacingValue(
        in toml: String,
        table: String,
        key: String,
        with replacement: String
    ) -> String {
        transform(toml) { currentTable, line in
            guard currentTable == table, line.hasPrefix("\(key) = ") else { return line }
            return "\(key) = \(replacement)"
        }
    }

    private func transform(
        _ toml: String,
        _ operation: (_ table: String, _ line: String) -> String?
    ) -> String {
        var currentTable = ""
        return toml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { substring -> String? in
                let line = String(substring)
                if line.hasPrefix("["), line.hasSuffix("]") {
                    currentTable = String(line.dropFirst().dropLast())
                }
                return operation(currentTable, line)
            }
            .joined(separator: "\n")
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMOverviewSettingsTests-\(UUID().uuidString)", isDirectory: true)
        return SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
    }
}
