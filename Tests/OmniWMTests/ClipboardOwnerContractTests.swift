// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class ClipboardOwnerContractTests: XCTestCase {
    func testObservationRemainsPerFieldAndDisabledAutosaveStaysSilent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory, autosaveEnabled: false)
        let originalData = try Data(contentsOf: settings.settingsFileURL)
        let changes = Mutex(0)
        withObservationTracking {
            _ = settings.clipboard.maxItems
        } onChange: {
            changes.withLock { $0 += 1 }
        }

        settings.clipboard.historyEnabled = true
        XCTAssertEqual(changes.withLock { $0 }, 0)
        var desired = settings.toExport()
        desired.clipboard.maxItems = 37
        settings.applyExport(desired)

        XCTAssertEqual(changes.withLock { $0 }, 1)
        XCTAssertEqual(settings.clipboard.maxItems, 37)
        XCTAssertEqual(try Data(contentsOf: settings.settingsFileURL), originalData)
    }

    func testObserverInvalidatesBeforeTheSynchronousSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory, autosaveEnabled: true)
        let fileURL = settings.settingsFileURL
        let originalData = try Data(contentsOf: fileURL)
        let observedData = Mutex<Data?>(nil)
        withObservationTracking {
            _ = settings.clipboard.historyEnabled
        } onChange: {
            observedData.withLock { $0 = try? Data(contentsOf: fileURL) }
        }

        settings.clipboard.historyEnabled = true

        XCTAssertEqual(observedData.withLock { $0 }, originalData)
        let saved = try SettingsLuauDocument(Data(contentsOf: fileURL)).export
        XCTAssertTrue(saved.clipboard.historyEnabled)
        XCTAssertEqual(saved, settings.toExport())
    }

    func testApplyGatesAllFourSavesAndLaterToggleSavesTheWholeExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory, autosaveEnabled: true)
        let originalData = try Data(contentsOf: settings.settingsFileURL)
        var desired = settings.toExport()
        desired.clipboard = SettingsExport.Clipboard(
            historyEnabled: true,
            maxItems: -1,
            maxItemBytes: 0,
            maxTotalBytes: 17
        )

        settings.applyExport(desired)

        XCTAssertEqual(settings.toExport(), desired)
        XCTAssertEqual(try Data(contentsOf: settings.settingsFileURL), originalData)
        settings.clipboard.historyEnabled = false
        desired.clipboard.historyEnabled = false
        let saved = try SettingsLuauDocument(Data(contentsOf: settings.settingsFileURL)).export
        XCTAssertEqual(saved, desired)
    }

    func testBlockedSaveNoticeStillObservesTheCompletedFieldWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = makeSettings(directory: directory, autosaveEnabled: true)
        let fileURL = settings.settingsFileURL
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
        let events = Mutex<[String]>([])
        withObservationTracking {
            _ = settings.clipboard.historyEnabled
        } onChange: {
            events.withLock { $0.append("historyWillChange") }
        }
        settings.onConfigNoticeChanged = {
            events.withLock { $0.append("notice:\(settings.clipboard.historyEnabled)") }
        }
        defer { settings.onConfigNoticeChanged = nil }

        settings.clipboard.historyEnabled = true

        XCTAssertEqual(events.withLock { $0 }, ["historyWillChange", "notice:true"])
        XCTAssertTrue(settings.settingsWritesBlocked)
        XCTAssertNotNil(settings.configNotice)
    }

    private func makeSettings(directory: URL, autosaveEnabled: Bool) -> SettingsStore {
        SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false),
            autosaveEnabled: autosaveEnabled
        )
    }
}
