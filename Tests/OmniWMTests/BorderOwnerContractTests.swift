// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class BorderOwnerContractTests: XCTestCase {
    func testDirectEditsKeepRawValuesAndObserveColorAsOneValue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        let color = SettingsColor(red: -2, green: 3, blue: 0.25, alpha: 0.75)
        let changes = Mutex<[String]>([])
        withObservationTracking {
            _ = settings.borders.color.red
        } onChange: {
            changes.withLock { $0.append("color") }
        }
        withObservationTracking {
            _ = settings.borders.width
        } onChange: {
            changes.withLock { $0.append("width") }
        }

        settings.borders.color = color
        XCTAssertEqual(changes.withLock { $0 }, ["color"])
        XCTAssertEqual(settings.borders.color, color)
        settings.borders.width = 99
        XCTAssertEqual(changes.withLock { $0 }, ["color", "width"])
        XCTAssertEqual(settings.borders.width, 99)
        let saved = try SettingsLuauDocument(Data(contentsOf: settings.settingsFileURL)).export
        XCTAssertEqual(saved.borders.color, color)
        XCTAssertEqual(saved.borders.width, 99)
        XCTAssertEqual(saved, settings.toExport())
    }

    func testImportRetainsOrderedClampingAndSaveGate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        let originalData = try Data(contentsOf: settings.settingsFileURL)
        let changes = Mutex<[String]>([])
        withObservationTracking {
            _ = settings.borders.enabled
        } onChange: {
            changes.withLock { $0.append("enabled") }
        }
        withObservationTracking {
            _ = settings.borders.width
        } onChange: {
            changes.withLock { $0.append("width") }
        }
        withObservationTracking {
            _ = settings.borders.color.blue
        } onChange: {
            changes.withLock { $0.append("color") }
        }
        var desired = settings.toExport()
        desired.borders = SettingsExport.Borders(
            enabled: false,
            width: 99,
            color: SettingsColor(red: -2, green: 3, blue: 0.25, alpha: 0.75)
        )

        settings.applyExport(desired)

        XCTAssertEqual(changes.withLock { $0 }, ["enabled", "width", "color"])
        XCTAssertFalse(settings.borders.enabled)
        XCTAssertEqual(settings.borders.width, 12)
        XCTAssertEqual(settings.borders.color, SettingsColor(red: 0, green: 1, blue: 0.25, alpha: 0.75))
        XCTAssertEqual(try Data(contentsOf: settings.settingsFileURL), originalData)
        settings.borders.enabled = true
        let saved = try SettingsLuauDocument(Data(contentsOf: settings.settingsFileURL)).export
        XCTAssertEqual(saved, settings.toExport())
    }

    private func makeSettings(directory: URL) -> SettingsStore {
        SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false),
            autosaveEnabled: true
        )
    }
}
