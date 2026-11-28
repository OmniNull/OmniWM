// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class KittyQuakeSettingsTests: XCTestCase {
    func testNativeDefaultsWriteNoKittyTable() throws {
        let settings = makeSettings()

        XCTAssertNil(SettingsExport.QuakeTerminal.defaults().kitty)
        XCTAssertTrue(settings.quakeTerminal.kitty.isNative)
        XCTAssertNil(settings.quakeTerminal.export().kitty)
        let quake = try quakeTable(SettingsLuauDocument.initialSource(settings.toExport()))
        XCTAssertNil(quake["kitty"])
    }

    func testKittyOverridesRoundTripThroughNestedLuauTables() throws {
        var export = SettingsExport.defaults()
        export.quakeTerminal.kitty = KittyQuakeSettings(
            autoHide: true,
            opacity: 0.9,
            placement: .init(position: .bottom, widthPercent: 80, heightPercent: 40)
        )

        let data = try SettingsLuauDocument.initialSource(export)

        XCTAssertEqual(try SettingsLuauFixture.decode(data), export)
        guard case let .record(kitty) = try XCTUnwrap(quakeTable(data)["kitty"]),
              case let .record(placement) = try XCTUnwrap(kitty["placement"])
        else {
            return XCTFail("Expected nested kitty and placement tables")
        }
        XCTAssertEqual(kitty["autoHide"], .boolean(true))
        XCTAssertEqual(kitty["opacity"], .number(0.9))
        XCTAssertEqual(placement["position"], .string("bottom"))
        XCTAssertEqual(placement["widthPercent"], .integer(80))
        XCTAssertEqual(placement["heightPercent"], .integer(40))
    }

    func testPartialOverridesKeepOtherKittyKeysNative() throws {
        var export = SettingsExport.defaults()
        export.quakeTerminal.kitty = KittyQuakeSettings(autoHide: false)

        let data = try SettingsLuauDocument.initialSource(export)
        guard case let .record(kitty) = try XCTUnwrap(quakeTable(data)["kitty"]) else {
            return XCTFail("Expected kitty table")
        }

        XCTAssertEqual(kitty.keys.sorted(), ["autoHide"])
        XCTAssertEqual(try SettingsLuauFixture.decode(data).quakeTerminal.kitty, KittyQuakeSettings(autoHide: false))
    }

    func testKittyValuesStayIndependentOfGhosttyValues() {
        let settings = makeSettings()
        let ghostty = settings.quakeTerminal.export()

        settings.quakeTerminal.kitty.placement = .defaultOverride
        settings.quakeTerminal.kitty.placement?.heightPercent = 40
        settings.quakeTerminal.kitty.opacity = QuakeOpacityOverride.defaultOverride
        settings.quakeTerminal.kitty.autoHide = true

        var withoutKitty = settings.quakeTerminal.export()
        XCTAssertEqual(withoutKitty.kitty, KittyQuakeSettings(
            autoHide: true,
            opacity: 0.85,
            placement: .init(position: .top, widthPercent: 100, heightPercent: 40)
        ))
        withoutKitty.kitty = nil
        XCTAssertEqual(withoutKitty, ghostty)
        XCTAssertEqual(settings.quakeTerminal.position, .center)
        XCTAssertEqual(settings.quakeTerminal.heightPercent, 50)
        XCTAssertEqual(settings.quakeTerminal.opacity, 1)
        XCTAssertFalse(settings.quakeTerminal.autoHide)

        settings.quakeTerminal.position = .left
        XCTAssertEqual(settings.quakeTerminal.kitty.placement?.position, .top)
    }

    func testImportReplacesKittyOverridesAndMissingTableReturnsToNative() {
        let settings = makeSettings()
        var values = settings.toExport()
        values.quakeTerminal.kitty = KittyQuakeSettings(opacity: 0.6)
        settings.applyExport(values)
        XCTAssertEqual(settings.quakeTerminal.kitty, KittyQuakeSettings(opacity: 0.6))

        values.quakeTerminal.kitty = nil
        settings.applyExport(values)
        XCTAssertTrue(settings.quakeTerminal.kitty.isNative)

        values.quakeTerminal.kitty = KittyQuakeSettings()
        settings.applyExport(values)
        XCTAssertNil(settings.quakeTerminal.export().kitty)
    }

    func testNormalizationClampsKittyDimensionsAndOpacity() {
        let settings = makeSettings()

        settings.quakeTerminal.kitty = KittyQuakeSettings(
            opacity: 1.5,
            placement: .init(position: .right, widthPercent: 200, heightPercent: .nan)
        )
        XCTAssertEqual(settings.quakeTerminal.kitty.opacity, 1)
        XCTAssertEqual(settings.quakeTerminal.kitty.placement?.widthPercent, 100)
        XCTAssertEqual(settings.quakeTerminal.kitty.placement?.heightPercent, 50)

        settings.quakeTerminal.kitty.opacity = -0.25
        XCTAssertEqual(settings.quakeTerminal.kitty.opacity, 0)
        settings.quakeTerminal.kitty.opacity = .infinity
        XCTAssertEqual(settings.quakeTerminal.kitty.opacity, QuakeOpacityOverride.defaultOverride)
        settings.quakeTerminal.kitty.placement?.widthPercent = 5
        XCTAssertEqual(settings.quakeTerminal.kitty.placement?.widthPercent, 10)
    }

    func testPlacementOverrideDefaultsToKittysTopEdgeNotGhosttysCenter() {
        XCTAssertEqual(
            QuakePlacementOverride.defaultOverride,
            .init(position: .top, widthPercent: 100, heightPercent: 50)
        )
        XCTAssertEqual(QuakeOpacityOverride.defaultOverride, 0.85)
    }

    private func quakeTable(_ data: Data) throws -> [String: SettingsLuauValue] {
        let tree = try SettingsLuauFixture.fields(in: data)
        guard case let .record(quake) = try XCTUnwrap(tree["quakeTerminal"]) else {
            XCTFail("Expected quakeTerminal table")
            return [:]
        }
        return quake
    }

    private func makeSettings() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("okqs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
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
