// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class HiddenBarOwnerContractTests: XCTestCase {
    func testDirectWritesPreserveRawArrayOrderAndUnclampedDelay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        let identifiers = [" com.example.second ", "com.example.first", "com.example.second", ""]

        settings.hiddenBar.hiddenBundleIDs = identifiers
        settings.hiddenBar.rehideIntervalSeconds = 99

        XCTAssertEqual(settings.hiddenBar.hiddenBundleIDs, identifiers)
        XCTAssertEqual(settings.hiddenBar.rehideIntervalSeconds, 99)
        let saved = try SettingsLuauDocument(Data(contentsOf: settings.settingsFileURL)).export
        XCTAssertEqual(saved.hiddenBar.hiddenBundleIDs, identifiers)
        XCTAssertEqual(saved.hiddenBar.rehideIntervalSeconds, 99)
        XCTAssertEqual(saved, settings.toExport())
    }

    func testImportAndSubsequentUIEditKeepNormalizationSaveAndReconcileOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory)
        let originalData = try Data(contentsOf: settings.settingsFileURL)
        let changes = Mutex<[String]>([])
        withObservationTracking {
            _ = settings.hiddenBar.enabled
        } onChange: {
            changes.withLock { $0.append("enabled") }
        }
        withObservationTracking {
            _ = settings.hiddenBar.hiddenBundleIDs
        } onChange: {
            changes.withLock { $0.append("identifiers") }
        }
        withObservationTracking {
            _ = settings.hiddenBar.rehideIntervalSeconds
        } onChange: {
            changes.withLock { $0.append("interval") }
        }
        var desired = settings.toExport()
        desired.hiddenBar = SettingsExport.HiddenBar(
            enabled: false,
            hiddenBundleIDs: [
                " com.example.second ",
                "com.apple.systemuiserver",
                "com.example.first",
                "com.example.second",
                ""
            ],
            rehideIntervalSeconds: 99
        )

        settings.applyExport(desired)

        XCTAssertEqual(changes.withLock { $0 }, ["enabled", "identifiers", "interval"])
        XCTAssertEqual(settings.hiddenBar.hiddenBundleIDs, ["com.example.second", "com.example.first"])
        XCTAssertEqual(settings.hiddenBar.rehideIntervalSeconds, 30)
        XCTAssertEqual(try Data(contentsOf: settings.settingsFileURL), originalData)
        var reconciliations = 0
        HiddenBarSettingsEdits.setHidden(true, bundleID: "com.example.third", settings: settings) {
            reconciliations += 1
            XCTAssertEqual(
                settings.hiddenBar.hiddenBundleIDs,
                ["com.example.second", "com.example.first", "com.example.third"]
            )
            let data = try? Data(contentsOf: settings.settingsFileURL)
            let saved = data.flatMap { try? SettingsLuauDocument($0).export }
            XCTAssertEqual(saved, settings.toExport())
        }
        XCTAssertEqual(reconciliations, 1)
    }

    private func makeSettings(directory: URL) -> SettingsStore {
        SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false),
            autosaveEnabled: true
        )
    }
}
