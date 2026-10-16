// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import TOML
import XCTest

final class IslandSettingsTests: XCTestCase {
    func testIslandIsDisabledByDefaultAndRoundTripsIndependentlyOfBar() throws {
        let defaults = SettingsExport.defaults()
        let tree = try TOMLDecoder().decode(
            [String: TOMLNode].self,
            from: SettingsTOMLCodec.encode(defaults)
        )
        XCTAssertEqual(tree["island"], .table(["enabled": .boolean(false)]))

        for barEnabled in [false, true] {
            for islandEnabled in [false, true] {
                var export = defaults
                export.workspaceBar.enabled = barEnabled
                export.island.enabled = islandEnabled
                XCTAssertEqual(try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export)), export)
            }
        }
    }

    func testAbsentIslandIsDisabledAndInvalidEnablementIsRejected() throws {
        var tree = try TOMLDecoder().decode(
            [String: TOMLNode].self,
            from: SettingsTOMLCodec.encode(.defaults())
        )
        tree.removeValue(forKey: "island")
        XCTAssertFalse(try SettingsTOMLCodec.decode(TOMLEncoder().encode(tree)).island.enabled)

        tree["island"] = .table(["enabled": .string("true")])
        XCTAssertThrowsError(try SettingsTOMLCodec.decode(TOMLEncoder().encode(tree)))
    }

    @MainActor
    func testIslandChangePersistsWithoutEnablingBarAndImportResetsIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false)
        )
        settings.workspaceBar.enabled = false
        settings.island.enabled = true

        let saved = try SettingsTOMLCodec.decode(Data(contentsOf: settings.settingsFileURL))
        XCTAssertTrue(saved.island.enabled)
        XCTAssertFalse(saved.workspaceBar.enabled)
        XCTAssertEqual(saved, settings.toExport())

        settings.applyExport(.defaults())
        XCTAssertFalse(settings.island.enabled)
        XCTAssertEqual(settings.toExport().island, .defaults())
    }
}
