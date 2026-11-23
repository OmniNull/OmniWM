// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class FootQuakeSettingsTests: XCTestCase {
    func testDefaultsWriteNoFootTableAndMeanDimOff() throws {
        let settings = makeSettings()

        XCTAssertNil(SettingsExport.QuakeTerminal.defaults().foot)
        XCTAssertEqual(settings.quakeTerminal.foot, FootQuakeSettings())
        XCTAssertEqual(settings.quakeTerminal.foot.dim, 0)
        XCTAssertTrue(settings.quakeTerminal.foot.isDefault)
        XCTAssertNil(settings.quakeTerminal.export().foot)
        XCTAssertNil(try quakeTable(SettingsLuauDocument.initialSource(settings.toExport()))["foot"])
    }

    func testFootProviderAndOverridesRoundTripThroughNestedLuauTables() throws {
        var export = SettingsExport.defaults()
        export.quakeTerminal.provider = .foot
        export.quakeTerminal.foot = FootQuakeSettings(
            autoHide: true,
            opacity: 0.9,
            placement: .init(position: .bottom, widthPercent: 80, heightPercent: 40),
            dim: 0.3
        )

        let data = try SettingsLuauDocument.initialSource(export)

        XCTAssertEqual(try SettingsLuauFixture.decode(data), export)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("provider = \"foot\""))
        guard case let .record(foot) = try XCTUnwrap(quakeTable(data)["foot"]),
              case let .record(placement) = try XCTUnwrap(foot["placement"])
        else {
            return XCTFail("Expected nested foot and placement tables")
        }
        XCTAssertEqual(foot["autoHide"], .boolean(true))
        XCTAssertEqual(foot["opacity"], .number(0.9))
        XCTAssertEqual(foot["dim"], .number(0.3))
        XCTAssertEqual(placement["position"], .string("bottom"))
        XCTAssertEqual(placement["widthPercent"], .integer(80))
        XCTAssertEqual(placement["heightPercent"], .integer(40))
    }

    func testOmittedDimDecodesAsOffAndPartialTablesKeepOtherOverridesUnset() throws {
        var export = SettingsExport.defaults()
        export.quakeTerminal.foot = FootQuakeSettings(autoHide: false)
        let data = try SettingsLuauDocument.initialSource(export)
        guard case let .record(foot) = try XCTUnwrap(quakeTable(data)["foot"]) else {
            return XCTFail("Expected foot table")
        }
        XCTAssertEqual(foot.keys.sorted(), ["autoHide", "dim"])

        let withoutDim = Data("return { quakeTerminal = { foot = { autoHide = true } } }".utf8)

        XCTAssertEqual(try SettingsLuauFixture.decode(withoutDim).quakeTerminal.foot, FootQuakeSettings(autoHide: true))
    }

    func testFootValuesStayIndependentOfGhosttyAndKitty() {
        let settings = makeSettings()
        settings.quakeTerminal.kitty = KittyQuakeSettings(opacity: 0.6)
        let before = settings.quakeTerminal.export()

        settings.quakeTerminal.foot.placement = .defaultOverride
        settings.quakeTerminal.foot.placement?.heightPercent = 40
        settings.quakeTerminal.foot.opacity = QuakeOpacityOverride.defaultOverride
        settings.quakeTerminal.foot.autoHide = true
        settings.quakeTerminal.foot.dim = 0.2

        var withoutFoot = settings.quakeTerminal.export()
        XCTAssertEqual(withoutFoot.foot, FootQuakeSettings(
            autoHide: true,
            opacity: 0.85,
            placement: .init(position: .top, widthPercent: 100, heightPercent: 40),
            dim: 0.2
        ))
        withoutFoot.foot = nil
        XCTAssertEqual(withoutFoot, before)
        XCTAssertEqual(settings.quakeTerminal.kitty, KittyQuakeSettings(opacity: 0.6))
        XCTAssertEqual(settings.quakeTerminal.position, .center)
        XCTAssertEqual(settings.quakeTerminal.opacity, 1)

        settings.quakeTerminal.kitty.placement = .init(position: .left, widthPercent: 30, heightPercent: 30)
        settings.quakeTerminal.position = .right
        XCTAssertEqual(settings.quakeTerminal.foot.placement?.position, .top)
        XCTAssertEqual(settings.quakeTerminal.foot.placement?.widthPercent, 100)
    }

    func testImportReplacesFootOverridesAndAMissingTableResetsThem() {
        let settings = makeSettings()
        var values = settings.toExport()
        values.quakeTerminal.foot = FootQuakeSettings(opacity: 0.4, dim: 0.6)
        settings.applyExport(values)
        XCTAssertEqual(settings.quakeTerminal.foot, FootQuakeSettings(opacity: 0.4, dim: 0.6))

        values.quakeTerminal.foot = nil
        settings.applyExport(values)
        XCTAssertTrue(settings.quakeTerminal.foot.isDefault)
        XCTAssertNil(settings.quakeTerminal.export().foot)
    }

    func testNormalizationClampsDimOpacityAndPlacementAndRejectsNonfiniteValues() {
        let settings = makeSettings()

        settings.quakeTerminal.foot = FootQuakeSettings(
            opacity: .nan,
            placement: .init(position: .right, widthPercent: 200, heightPercent: .nan),
            dim: 1.5
        )
        XCTAssertEqual(settings.quakeTerminal.foot.opacity, QuakeOpacityOverride.defaultOverride)
        XCTAssertEqual(settings.quakeTerminal.foot.placement?.widthPercent, 100)
        XCTAssertEqual(settings.quakeTerminal.foot.placement?.heightPercent, 50)
        XCTAssertEqual(settings.quakeTerminal.foot.dim, 1)

        for (dim, expected) in [(-0.25, 0.0), (Double.nan, 0), (.infinity, 0), (0.45, 0.45)] {
            settings.quakeTerminal.foot.dim = dim
            XCTAssertEqual(settings.quakeTerminal.foot.dim, expected)
        }
        settings.quakeTerminal.foot.opacity = -1
        XCTAssertEqual(settings.quakeTerminal.foot.opacity, 0)
        settings.quakeTerminal.foot.placement?.widthPercent = 5
        XCTAssertEqual(settings.quakeTerminal.foot.placement?.widthPercent, 10)
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
            .appendingPathComponent("ofqs-\(UUID().uuidString.prefix(8))", isDirectory: true)
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
