// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class EdgeNavigationSettingsTests: XCTestCase {
    func testIntervalObserverNormalizesAndNotifiesOnce() {
        let focus = FocusSettings()
        XCTAssertEqual(focus.edgeNavigationInterval, 1.5)
        var changes = 0
        focus.onChange = { changes += 1 }

        for interval in stride(from: 0.25, through: 2.0, by: 0.25) {
            changes = 0
            focus.edgeNavigationInterval = interval
            XCTAssertEqual(focus.edgeNavigationInterval, interval)
            XCTAssertEqual(changes, 1)
        }
        for (value, expected) in [
            (Double.nan, 1.5), (.infinity, 1.5), (-.infinity, 1.5),
            (-1.0, 0.25), (0.374, 0.25), (0.375, 0.5), (1.375, 1.5), (3.0, 2.0)
        ] {
            changes = 0
            focus.edgeNavigationInterval = value
            XCTAssertEqual(focus.edgeNavigationInterval, expected)
            XCTAssertEqual(changes, 1)
        }
    }

    func testImportAndPersistedEditsUseTheFocusOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false)
        )
        let focus = settings.focus
        var imported = settings.toExport()
        imported.focus.edgeNavigationInterval = 0.375

        settings.applyExport(imported)

        XCTAssertTrue(settings.focus === focus)
        XCTAssertEqual(focus.edgeNavigationInterval, 0.5)
        focus.edgeNavigationInterval = 1.25
        XCTAssertEqual(settings.toExport().focus.edgeNavigationInterval, 1.25)
        let saved = try SettingsLuauDocument(Data(contentsOf: settings.settingsFileURL)).export
        XCTAssertEqual(saved.focus.edgeNavigationInterval, 1.25)
        let reloaded = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false)
        )
        XCTAssertEqual(reloaded.focus.edgeNavigationInterval, 1.25)
    }
}
