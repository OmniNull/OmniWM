// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import Observation
@testable import OmniWM
import Synchronization
import XCTest

final class WorkspaceBarNotificationBadgeSettingsTests: XCTestCase {
    func testDefaultsRoundTrip() throws {
        let export = SettingsExport.defaults()
        XCTAssertEqual(export.workspaceBar.notificationBadges, .off)
        XCTAssertEqual(export.workspaceBar.notificationBadgeRefreshIntervalSeconds, 5)

        let data = try SettingsTOMLCodec.encode(export)
        let toml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(toml.contains("notificationBadges = \"off\""))
        XCTAssertTrue(toml.contains("notificationBadgeRefreshIntervalSeconds = 5"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(data), export)
    }

    func testBadgeModesRoundTrip() throws {
        for mode in WorkspaceBarNotificationBadgeMode.allCases {
            var export = SettingsExport.defaults()
            export.workspaceBar.notificationBadges = mode
            export.workspaceBar.notificationBadgeRefreshIntervalSeconds = 19

            let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
            XCTAssertEqual(decoded.workspaceBar.notificationBadges, mode)
            XCTAssertEqual(decoded.workspaceBar.notificationBadgeRefreshIntervalSeconds, 19)
        }
    }

    func testMissingBadgeKeysUseDefaults() throws {
        let toml = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let withoutBadgeKeys = toml.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("notificationBadge") }
            .joined(separator: "\n")
        let decoded = try SettingsTOMLCodec.decode(Data(withoutBadgeKeys.utf8))

        XCTAssertEqual(decoded.workspaceBar.notificationBadges, .off)
        XCTAssertEqual(decoded.workspaceBar.notificationBadgeRefreshIntervalSeconds, 5)
    }

    @MainActor
    func testIntervalNormalizesAndPublishesOncePerAssignment() {
        let settings = WorkspaceBarSettings()
        var changes = 0
        settings.onNotificationBadgesChange = { changes += 1 }
        let cases: [(Double, Double)] = [
            (-10, 1), (0, 1), (1, 1), (1.4, 1), (1.5, 2),
            (30.7, 31), (60, 60), (90, 60), (.nan, 5), (.infinity, 5), (-.infinity, 5)
        ]

        for (index, values) in cases.enumerated() {
            settings.notificationBadgeRefreshIntervalSeconds = values.0
            XCTAssertEqual(settings.notificationBadgeRefreshIntervalSeconds, values.1)
            XCTAssertEqual(changes, index + 1)
        }
    }

    @MainActor
    func testApplyExportNormalizesAndExportsBadgeSettings() {
        let settings = WorkspaceBarSettings()
        var export = SettingsExport.WorkspaceBar.defaults()
        export.notificationBadges = .text
        export.notificationBadgeRefreshIntervalSeconds = 12.7

        settings.applyIdentity(export)

        XCTAssertEqual(settings.notificationBadges, .text)
        XCTAssertEqual(settings.notificationBadgeRefreshIntervalSeconds, 13)
        XCTAssertEqual(settings.export().notificationBadges, .text)
        XCTAssertEqual(settings.export().notificationBadgeRefreshIntervalSeconds, 13)
    }

    @MainActor
    func testBadgeSettingsPersistWithoutInvalidatingLayoutConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false)
        let settings = SettingsStore(
            persistence: persistence,
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false)
        )
        let revision = settings.layoutConfigurationRevision
        let changes = Mutex(0)
        withObservationTracking {
            _ = settings.toExport()
        } onChange: {
            changes.withLock { $0 += 1 }
        }

        settings.workspaceBar.notificationBadges = .dot
        XCTAssertEqual(changes.withLock { $0 }, 1)

        withObservationTracking {
            _ = settings.toExport()
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        settings.workspaceBar.notificationBadgeRefreshIntervalSeconds = 17

        XCTAssertEqual(changes.withLock { $0 }, 2)
        XCTAssertEqual(settings.layoutConfigurationRevision, revision)
        let saved = try XCTUnwrap(persistence.loadOutcome().export)
        XCTAssertEqual(saved.workspaceBar.notificationBadges, .dot)
        XCTAssertEqual(saved.workspaceBar.notificationBadgeRefreshIntervalSeconds, 17)
    }
}
