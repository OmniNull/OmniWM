// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class WorkspaceBarAppearanceSettingsTests: XCTestCase {
    func testAppearanceDefaultsAndRoundTrips() throws {
        var export = SettingsExport.defaults()
        XCTAssertNil(export.workspaceBar.inactiveIconOpacity)
        XCTAssertFalse(export.workspaceBar.transparentBackground)
        XCTAssertFalse(export.workspaceBar.solidBlackBackground)
        XCTAssertTrue(export.workspaceBar.showItemBackgrounds)
        XCTAssertTrue(export.workspaceBar.showAccentHighlights)

        export.workspaceBar.transparentBackground = true
        export.workspaceBar.solidBlackBackground = true
        export.workspaceBar.showItemBackgrounds = false
        export.workspaceBar.showAccentHighlights = false
        export.workspaceBar.inactiveIconOpacity = 0.25
        let data = try SettingsLuauDocument.initialSource(export)
        let source = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(source.contains("transparentBackground = true"))
        XCTAssertTrue(source.contains("solidBlackBackground = true"))
        XCTAssertTrue(source.contains("showItemBackgrounds = false"))
        XCTAssertTrue(source.contains("showAccentHighlights = false"))
        XCTAssertTrue(source.contains("inactiveIconOpacity = 0.25"))
        let decoded = try SettingsLuauFixture.decode(data)
        XCTAssertTrue(decoded.workspaceBar.transparentBackground)
        XCTAssertTrue(decoded.workspaceBar.solidBlackBackground)
        XCTAssertFalse(decoded.workspaceBar.showItemBackgrounds)
        XCTAssertFalse(decoded.workspaceBar.showAccentHighlights)
        XCTAssertEqual(decoded.workspaceBar.inactiveIconOpacity, 0.25)
    }

    func testOmittedAppearanceSettingsUseDefaults() throws {
        let data = try SettingsLuauDocument.initialSource(.defaults())
        let source = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter {
                !$0.contains("inactiveIconOpacity") &&
                    !$0.contains("transparentBackground") &&
                    !$0.contains("solidBlackBackground") &&
                    !$0.contains("showItemBackgrounds") &&
                    !$0.contains("showAccentHighlights")
            }
            .joined(separator: "\n")

        let result = try SettingsLuauDocument(Data(source.utf8))

        XCTAssertFalse(result.export.workspaceBar.transparentBackground)
        XCTAssertFalse(result.export.workspaceBar.solidBlackBackground)
        XCTAssertTrue(result.export.workspaceBar.showItemBackgrounds)
        XCTAssertTrue(result.export.workspaceBar.showAccentHighlights)
        XCTAssertNil(result.export.workspaceBar.inactiveIconOpacity)
    }

    func testCurrentSchemaRejectsInvalidAppearanceType() throws {
        var export = SettingsExport.defaults()
        export.workspaceBar.inactiveIconOpacity = 0.5
        export.monitorBarSettings = [MonitorBarSettings(
            monitorName: "Built-in",
            inactiveIconOpacity: 0.5,
            transparentBackground: false,
            solidBlackBackground: false,
            showItemBackgrounds: true,
            showAccentHighlights: true
        )]
        let source = String(decoding: try SettingsLuauDocument.initialSource(export), as: UTF8.self)
        for keyValue in [
            "transparentBackground = false",
            "solidBlackBackground = false",
            "showItemBackgrounds = true",
            "showAccentHighlights = true",
            "inactiveIconOpacity = 0.5"
        ] {
            let key = keyValue.components(separatedBy: " = ")[0]
            let matches = source.ranges(of: keyValue)
            XCTAssertEqual(matches.count, 2, key)
            for range in matches {
                var invalid = source
                invalid.replaceSubrange(range, with: "\(key) = \"invalid\"")
                XCTAssertThrowsError(try SettingsLuauFixture.decode(Data(invalid.utf8)), key)
            }
        }
    }

    func testMonitorAppearanceOverrideRoundTrips() throws {
        var export = SettingsExport.defaults()
        export.monitorBarSettings = [
            MonitorBarSettings(
                monitorName: "Built-in",
                inactiveIconOpacity: 0.2,
                transparentBackground: true,
                solidBlackBackground: true,
                showItemBackgrounds: false,
                showAccentHighlights: false
            ),
            MonitorBarSettings(monitorName: "External")
        ]

        let decoded = try SettingsLuauFixture.decode(SettingsLuauDocument.initialSource(export))

        XCTAssertEqual(decoded.monitorBarSettings[0].inactiveIconOpacity, 0.2)
        XCTAssertEqual(decoded.monitorBarSettings[0].transparentBackground, true)
        XCTAssertEqual(decoded.monitorBarSettings[0].solidBlackBackground, true)
        XCTAssertEqual(decoded.monitorBarSettings[0].showItemBackgrounds, false)
        XCTAssertEqual(decoded.monitorBarSettings[0].showAccentHighlights, false)
        XCTAssertNil(decoded.monitorBarSettings[1].inactiveIconOpacity)
        XCTAssertNil(decoded.monitorBarSettings[1].transparentBackground)
        XCTAssertNil(decoded.monitorBarSettings[1].solidBlackBackground)
        XCTAssertNil(decoded.monitorBarSettings[1].showItemBackgrounds)
        XCTAssertNil(decoded.monitorBarSettings[1].showAccentHighlights)
    }

    @MainActor
    func testResolvedBarSettingsMergesAppearanceOverride() {
        let settings = makeSettingsStore()
        settings.workspaceBar.inactiveIconOpacity = 0.5
        settings.workspaceBar.transparentBackground = false
        settings.workspaceBar.solidBlackBackground = false
        settings.workspaceBar.showItemBackgrounds = true
        settings.workspaceBar.showAccentHighlights = true
        let monitor = Monitor(
            id: .init(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            hasNotch: true,
            name: "Built-in"
        )

        let resolved = settings.workspaceBar.resolved(for: monitor)
        XCTAssertEqual(resolved.inactiveIconOpacity, 0.5)
        XCTAssertFalse(resolved.transparentBackground)
        XCTAssertFalse(resolved.solidBlackBackground)
        XCTAssertTrue(resolved.showItemBackgrounds)
        XCTAssertTrue(resolved.showAccentHighlights)

        settings.workspaceBar.update(
            MonitorBarSettings(
                monitorName: "Built-in",
                inactiveIconOpacity: 0.2,
                transparentBackground: true,
                solidBlackBackground: true,
                showItemBackgrounds: false,
                showAccentHighlights: false
            ),
            for: monitor
        )

        let resolvedOverride = settings.workspaceBar.resolved(for: monitor)
        XCTAssertEqual(resolvedOverride.inactiveIconOpacity, 0.2)
        XCTAssertTrue(resolvedOverride.transparentBackground)
        XCTAssertTrue(resolvedOverride.solidBlackBackground)
        XCTAssertFalse(resolvedOverride.showItemBackgrounds)
        XCTAssertFalse(resolvedOverride.showAccentHighlights)
    }

    @MainActor
    func testAppearanceSettingsApplyAndExport() {
        let settings = makeSettingsStore()
        var export = SettingsExport.defaults()
        export.workspaceBar.inactiveIconOpacity = 0.3
        export.workspaceBar.transparentBackground = true
        export.workspaceBar.solidBlackBackground = true
        export.workspaceBar.showItemBackgrounds = false
        export.workspaceBar.showAccentHighlights = false

        settings.applyExport(export)

        XCTAssertEqual(settings.toExport().workspaceBar, export.workspaceBar)
        XCTAssertEqual(settings.workspaceBar.inactiveIconOpacity, 0.3)
        XCTAssertTrue(settings.workspaceBar.transparentBackground)
        XCTAssertTrue(settings.workspaceBar.solidBlackBackground)
        XCTAssertFalse(settings.workspaceBar.showItemBackgrounds)
        XCTAssertFalse(settings.workspaceBar.showAccentHighlights)
    }

    @MainActor
    func testNonfiniteOpacityRejectsTheSettingsFile() throws {
        var export = SettingsExport.defaults()
        export.workspaceBar.inactiveIconOpacity = 0.5
        export.monitorBarSettings = [MonitorBarSettings(monitorName: "Built-in", inactiveIconOpacity: 0.5)]
        let source = String(decoding: try SettingsLuauDocument.initialSource(export), as: UTF8.self)

        for literal in ["math.huge", "-math.huge", "(0 / 0)"] {
            let data = Data(source.replacingOccurrences(
                of: "inactiveIconOpacity = 0.5",
                with: "inactiveIconOpacity = \(literal)"
            ).utf8)
            XCTAssertThrowsError(try SettingsLuauFixture.decode(data), literal)
        }
    }

    @MainActor
    func testProgrammaticOpacityNormalizesBeforeResolutionAndExport() {
        let settings = makeSettingsStore()
        let monitor = makeMonitor()
        let cases: [(Double?, Double?)] = [
            (nil, nil), (.nan, nil), (.infinity, nil), (-.infinity, nil),
            (-1, 0), (0, 0), (0.35, 0.35), (1, 1), (2, 1), (.greatestFiniteMagnitude, 1)
        ]
        for (input, expected) in cases {
            settings.workspaceBar.inactiveIconOpacity = input
            settings.workspaceBar.update(
                MonitorBarSettings(monitorName: monitor.name, inactiveIconOpacity: input),
                for: monitor
            )

            XCTAssertEqual(settings.workspaceBar.inactiveIconOpacity, expected)
            XCTAssertEqual(settings.workspaceBar.settings(for: monitor)?.inactiveIconOpacity, expected)
            XCTAssertEqual(settings.workspaceBar.resolved(for: monitor).inactiveIconOpacity, expected)
            XCTAssertEqual(settings.toExport().workspaceBar.inactiveIconOpacity, expected)
            XCTAssertEqual(settings.toExport().monitorBarSettings.first?.inactiveIconOpacity, expected)
        }

        settings.workspaceBar.monitorOverrides[0].inactiveIconOpacity = .nan
        XCTAssertNil(settings.workspaceBar.monitorOverrides[0].inactiveIconOpacity)
    }

    @MainActor
    func testNilAppearanceOverrideFieldsFallBackToGlobalValues() {
        let cases: [(
            opacity: Double,
            transparent: Bool,
            solidBlack: Bool,
            itemBackgrounds: Bool,
            accentHighlights: Bool
        )] = [
            (0.8, true, true, true, true),
            (0.5, false, false, true, true)
        ]
        for row in cases {
            let settings = makeSettingsStore()
            let monitor = makeMonitor()
            settings.workspaceBar.inactiveIconOpacity = row.opacity
            settings.workspaceBar.transparentBackground = row.transparent
            settings.workspaceBar.solidBlackBackground = row.solidBlack
            settings.workspaceBar.showItemBackgrounds = row.itemBackgrounds
            settings.workspaceBar.showAccentHighlights = row.accentHighlights
            settings.workspaceBar.update(
                MonitorBarSettings(
                    monitorName: monitor.name, monitorDisplayUUID: monitor.displayUUID,
                    monitorDisplayId: monitor.displayId,
                    inactiveIconOpacity: 0.2, transparentBackground: false, solidBlackBackground: false,
                    showItemBackgrounds: false, showAccentHighlights: false
                ),
                for: monitor
            )
            let explicit = settings.workspaceBar.resolved(for: monitor)
            XCTAssertEqual(explicit.inactiveIconOpacity, 0.2)
            XCTAssertFalse(explicit.transparentBackground)
            XCTAssertFalse(explicit.solidBlackBackground)
            XCTAssertFalse(explicit.showItemBackgrounds)
            XCTAssertFalse(explicit.showAccentHighlights)

            settings.workspaceBar.update(
                MonitorBarSettings(
                    monitorName: monitor.name, monitorDisplayUUID: monitor.displayUUID,
                    monitorDisplayId: monitor.displayId
                ),
                for: monitor
            )
            let fallback = settings.workspaceBar.resolved(for: monitor)
            XCTAssertEqual(fallback.inactiveIconOpacity, row.opacity)
            XCTAssertEqual(fallback.transparentBackground, row.transparent)
            XCTAssertEqual(fallback.solidBlackBackground, row.solidBlack)
            XCTAssertEqual(fallback.showItemBackgrounds, row.itemBackgrounds)
            XCTAssertEqual(fallback.showAccentHighlights, row.accentHighlights)
            settings.workspaceBar.inactiveIconOpacity = nil
            XCTAssertNil(settings.workspaceBar.resolved(for: monitor).inactiveIconOpacity)
        }
    }
}

private extension WorkspaceBarAppearanceSettingsTests {
    @MainActor
    func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMBarAppearanceTests-\(UUID().uuidString)", isDirectory: true)
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

    func makeMonitor() -> Monitor {
        Monitor(
            id: .init(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            hasNotch: true,
            name: "Built-in"
        )
    }
}
