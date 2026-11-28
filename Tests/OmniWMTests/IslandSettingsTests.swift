// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class IslandSettingsTests: XCTestCase {
    func testIslandIsDisabledByDefaultAndRoundTripsIndependentlyOfBar() throws {
        let defaults = SettingsExport.defaults()
        let tree = try SettingsLuauFixture.fields(in: SettingsLuauDocument.initialSource(defaults))
        XCTAssertEqual(tree["island"], .record(["enabled": .boolean(false)]))

        for barEnabled in [false, true] {
            for islandEnabled in [false, true] {
                var export = defaults
                export.workspaceBar.enabled = barEnabled
                export.island.enabled = islandEnabled
                XCTAssertEqual(try SettingsLuauFixture.decode(SettingsLuauDocument.initialSource(export)), export)
            }
        }
    }

    func testAbsentIslandIsDisabledAndInvalidEnablementIsRejected() throws {
        var tree = try SettingsLuauFixture.fields(in: SettingsLuauDocument.initialSource(.defaults()))
        tree.removeValue(forKey: "island")
        XCTAssertFalse(try SettingsLuauFixture.decode(SettingsLuauFixture.source(tree)).island.enabled)

        tree["island"] = .record(["enabled": .string("true")])
        XCTAssertThrowsError(try SettingsLuauFixture.decode(SettingsLuauFixture.source(tree)))
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

        let saved = try SettingsLuauDocument(Data(contentsOf: settings.settingsFileURL)).export
        XCTAssertTrue(saved.island.enabled)
        XCTAssertFalse(saved.workspaceBar.enabled)
        XCTAssertEqual(saved, settings.toExport())

        settings.applyExport(.defaults())
        XCTAssertFalse(settings.island.enabled)
        XCTAssertEqual(settings.toExport().island, .defaults())
    }
}
