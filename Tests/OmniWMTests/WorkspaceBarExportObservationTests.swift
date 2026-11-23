// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import Synchronization
import XCTest

final class WorkspaceBarExportObservationTests: XCTestCase {
    @MainActor
    func testSnapshotTracksPropertiesOnBothSidesOfScratchpadLabels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false),
            autosaveEnabled: false
        )
        let changes = Mutex(0)
        withObservationTracking {
            _ = settings.toExport()
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        settings.workspaceBar.enabled.toggle()
        XCTAssertEqual(changes.withLock { $0 }, 1)

        withObservationTracking {
            _ = settings.toExport()
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        settings.workspaceBar.textColor = SettingsColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
        XCTAssertEqual(changes.withLock { $0 }, 2)
        XCTAssertEqual(settings.toExport().workspaceBar.textColor, settings.workspaceBar.textColor)
    }

    func testBothWorkspaceBarColorsRemainOptionalInCodec() throws {
        var export = SettingsExport.defaults()
        export.workspaceBar.accentColor = nil
        export.workspaceBar.textColor = nil
        export.scratchpads.labels = ["3": "COMMS"]

        XCTAssertEqual(try SettingsLuauFixture.decode(SettingsLuauDocument.initialSource(export)), export)
    }
}
