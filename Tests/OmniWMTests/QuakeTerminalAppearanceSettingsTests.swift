// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class QuakeTerminalAppearanceSettingsTests: XCTestCase {
    func testBackgroundEffectDefaultsToStandardBlur() {
        XCTAssertEqual(SettingsExport.defaults().quakeTerminal.backgroundEffect, .standardBlur)
    }

    func testBackgroundBlurDefaultsToOff() {
        let defaults = SettingsExport.defaults()

        XCTAssertEqual(
            defaults.quakeTerminal.backgroundBlurRadius,
            QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius
        )
    }

    func testNormalizedBackgroundBlurRadiusClampsToSupportedRange() {
        XCTAssertEqual(QuakeTerminalAppearancePolicy.normalizedBackgroundBlurRadius(-30), 0)
        XCTAssertEqual(QuakeTerminalAppearancePolicy.normalizedBackgroundBlurRadius(0), 0)
        XCTAssertEqual(QuakeTerminalAppearancePolicy.normalizedBackgroundBlurRadius(20), 20)
        XCTAssertEqual(QuakeTerminalAppearancePolicy.normalizedBackgroundBlurRadius(1000), 100)
    }

    func testGhosttyGlassDisablesNumericBackgroundBlur() {
        XCTAssertEqual(
            QuakeTerminalAppearancePolicy.effectiveBackgroundBlurRadius(40, glassEffectActive: true),
            0
        )
        XCTAssertEqual(
            QuakeTerminalAppearancePolicy.effectiveBackgroundBlurRadius(40, glassEffectActive: false),
            40
        )
    }

    func testBackgroundBlurIsOnlyVisibleThroughATranslucentTerminal() {
        let policy = QuakeTerminalAppearancePolicy.self

        XCTAssertFalse(policy.backgroundBlurIsHiddenByOpaqueBackground(radius: 0, opacity: 1.0))
        XCTAssertFalse(policy.backgroundBlurIsHiddenByOpaqueBackground(radius: 20, opacity: 0.85))
        XCTAssertTrue(policy.backgroundBlurIsHiddenByOpaqueBackground(radius: 20, opacity: 1.0))
    }

    func testRoundTripsBackgroundBlurRadiusInQuakeTerminalTable() throws {
        var export = SettingsExport.defaults()
        export.quakeTerminal.backgroundBlurRadius = 35

        let data = try SettingsLuauDocument.initialSource(export)
        let source = String(decoding: data, as: UTF8.self)
        let decoded = try SettingsLuauFixture.decode(data)

        XCTAssertTrue(source.contains("quakeTerminal = {"))
        XCTAssertTrue(source.contains("backgroundBlurRadius = 35"))
        XCTAssertEqual(decoded.quakeTerminal.backgroundBlurRadius, 35)
    }

    func testRoundTripsEveryBackgroundEffectInQuakeTerminalTable() throws {
        for effect in QuakeTerminalBackgroundEffect.allCases {
            var export = SettingsExport.defaults()
            export.quakeTerminal.backgroundEffect = effect

            let data = try SettingsLuauDocument.initialSource(export)
            let source = String(decoding: data, as: UTF8.self)
            let decoded = try SettingsLuauFixture.decode(data)

            XCTAssertTrue(source.contains("backgroundEffect = \"\(effect.rawValue)\""))
            XCTAssertEqual(decoded.quakeTerminal.backgroundEffect, effect)
        }
    }

    @MainActor
    func testConfigWithoutBackgroundBlurRadiusDecodesToOff() throws {
        let decoded = try SettingsLuauFixture.decode(Data("return { quakeTerminal = {} }".utf8))
        XCTAssertEqual(
            decoded.quakeTerminal.backgroundBlurRadius,
            SettingsExport.defaults().quakeTerminal.backgroundBlurRadius
        )
        let settings = makeSettingsStore()
        settings.applyExport(decoded)
        XCTAssertEqual(
            settings.quakeTerminal.backgroundBlurRadius,
            QuakeTerminalAppearancePolicy.disabledBackgroundBlurRadius
        )
    }

    func testMalformedBackgroundBlurRadiusRejectsDecode() throws {
        let invalid = Data("return { quakeTerminal = { backgroundBlurRadius = 'heavy' } }".utf8)
        XCTAssertThrowsError(try SettingsLuauFixture.decode(invalid)) { error in
            XCTAssertTrue(error.localizedDescription.contains("quakeTerminal.backgroundBlurRadius"))
        }
    }

    @MainActor
    func testApplyExportClampsBackgroundBlurRadius() {
        let settings = makeSettingsStore()
        var export = SettingsExport.defaults()

        export.quakeTerminal.backgroundBlurRadius = -5
        settings.applyExport(export)
        XCTAssertEqual(settings.quakeTerminal.backgroundBlurRadius, 0)

        export.quakeTerminal.backgroundBlurRadius = 400
        settings.applyExport(export)
        XCTAssertEqual(settings.quakeTerminal.backgroundBlurRadius, 100)
        XCTAssertEqual(settings.toExport().quakeTerminal.backgroundBlurRadius, 100)
    }

    func testUnknownBackgroundEffectRejectsDecode() throws {
        let source = String(decoding: try SettingsLuauDocument.initialSource(.defaults()), as: UTF8.self)
            .replacingOccurrences(
                of: "backgroundEffect = \"\(QuakeTerminalBackgroundEffect.standardBlur.rawValue)\"",
                with: "backgroundEffect = \"futureGlass\""
            )

        XCTAssertThrowsError(try SettingsLuauFixture.decode(Data(source.utf8))) { error in
            XCTAssertTrue(SettingsLuauError.diagnosticDescription(for: error)
                .contains("quakeTerminal.backgroundEffect"))
        }
    }

    @MainActor
    func testAssigningOutOfRangeBackgroundBlurRadiusNormalizesInPlace() {
        let settings = makeSettingsStore()

        settings.quakeTerminal.backgroundBlurRadius = 250
        XCTAssertEqual(settings.quakeTerminal.backgroundBlurRadius, 100)

        settings.quakeTerminal.backgroundBlurRadius = -1
        XCTAssertEqual(settings.quakeTerminal.backgroundBlurRadius, 0)
    }

    @MainActor
    func testAutosavePersistsBackgroundBlurRadius() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMQuakeAppearanceAutosaveTests-\(UUID().uuidString)", isDirectory: true)
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

        settings.quakeTerminal.backgroundBlurRadius = 40
        settings.quakeTerminal.backgroundEffect = .glassClear

        let persisted = try SettingsLuauDocument(Data(contentsOf: persistence.fileURL)).export
        XCTAssertEqual(persisted.quakeTerminal.backgroundBlurRadius, 40)
        XCTAssertEqual(persisted.quakeTerminal.backgroundEffect, .glassClear)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMQuakeAppearanceSettingsTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
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
