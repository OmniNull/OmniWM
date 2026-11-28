// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceBarExcludedAppsSettingsTests: XCTestCase {
    func testDefaultsEncodeAsEmptyList() throws {
        XCTAssertEqual(SettingsExport.defaults().workspaceBar.excludedBundleIDs, [])

        let canonical = try XCTUnwrap(
            String(
                bytes: SettingsLuauDocument.initialSource(.defaults()),
                encoding: .utf8
            )
        )
        XCTAssertTrue(canonical.contains("excludedBundleIDs = {}"))
    }

    func testCanonicalAndPreservingRoundTripsKeepBundleIDs() throws {
        var export = SettingsExport.defaults()
        export.workspaceBar.excludedBundleIDs = [
            "tracesOf.Uebersicht",
            "com.example.Offline"
        ]

        let canonical = try SettingsLuauDocument.initialSource(export)
        XCTAssertEqual(
            try SettingsLuauFixture.fields(in: canonical)["workspaceBar"]?["excludedBundleIDs"],
            .list(export.workspaceBar.excludedBundleIDs.map(SettingsLuauValue.string))
        )
        XCTAssertEqual(
            try SettingsLuauFixture.decode(canonical).workspaceBar.excludedBundleIDs,
            export.workspaceBar.excludedBundleIDs
        )

        let preserving = try SettingsLuauFixture.editing(canonical, to: export)
        XCTAssertEqual(
            try SettingsLuauFixture.decode(preserving).workspaceBar.excludedBundleIDs,
            export.workspaceBar.excludedBundleIDs
        )
    }

    func testApplyExportNormalizesAndExportSortsDeterministically() {
        let settings = makeSettingsStore()
        var export = SettingsExport.defaults()
        export.workspaceBar.excludedBundleIDs = [
            "  com.Zeta  ",
            "com.beta",
            "",
            "\n",
            "COM.BETA",
            "com.Alpha"
        ]

        settings.applyExport(export)

        XCTAssertEqual(
            settings.workspaceBar.excludedBundleIDs,
            Set(["com.Zeta", "com.beta", "com.Alpha"])
        )
        XCTAssertEqual(
            settings.toExport().workspaceBar.excludedBundleIDs,
            ["com.Alpha", "com.beta", "com.Zeta"]
        )
    }

    func testAddAndRemoveAreTrimmedCaseInsensitiveAndReportNoOps() {
        let settings = makeSettingsStore()

        XCTAssertFalse(settings.workspaceBar.addExcludedBundleID("  \n"))
        XCTAssertTrue(settings.workspaceBar.addExcludedBundleID("  com.Example.One  "))
        XCTAssertEqual(settings.workspaceBar.excludedBundleIDs, ["com.Example.One"])
        XCTAssertFalse(settings.workspaceBar.addExcludedBundleID("COM.EXAMPLE.ONE"))
        XCTAssertTrue(settings.workspaceBar.removeExcludedBundleID("  COM.EXAMPLE.ONE  "))
        XCTAssertTrue(settings.workspaceBar.excludedBundleIDs.isEmpty)
        XCTAssertFalse(settings.workspaceBar.removeExcludedBundleID("com.example.one"))
    }

    func testUIEditsRefreshOnceOnlyWhenTheExclusionChanges() {
        let settings = makeSettingsStore()
        var refreshCount = 0
        let refresh = { refreshCount += 1 }

        XCTAssertTrue(
            WorkspaceBarExcludedAppsEdits.setExcluded(
                true,
                bundleID: "com.Example.One",
                settings: settings,
                refresh: refresh
            )
        )
        XCTAssertEqual(refreshCount, 1)
        XCTAssertFalse(
            WorkspaceBarExcludedAppsEdits.setExcluded(
                true,
                bundleID: "COM.EXAMPLE.ONE",
                settings: settings,
                refresh: refresh
            )
        )
        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(
            WorkspaceBarExcludedAppsEdits.setExcluded(
                false,
                bundleID: "COM.EXAMPLE.ONE",
                settings: settings,
                refresh: refresh
            )
        )
        XCTAssertEqual(refreshCount, 2)
        XCTAssertFalse(
            WorkspaceBarExcludedAppsEdits.setExcluded(
                false,
                bundleID: "com.example.one",
                settings: settings,
                refresh: refresh
            )
        )
        XCTAssertEqual(refreshCount, 2)
    }

    func testResolvedSettingsUseTheSameGlobalExclusionsOnEveryMonitor() {
        let settings = makeSettingsStore()
        XCTAssertTrue(settings.workspaceBar.addExcludedBundleID("com.example.global"))
        let first = monitor(displayId: 41_001, name: "First", x: 0)
        let second = monitor(displayId: 41_002, name: "Second", x: 1440)

        settings.workspaceBar.update(
            MonitorBarSettings(
                monitorName: second.name,
                monitorDisplayId: second.displayId,
                hideEmptyWorkspaces: true
            ),
            for: second
        )

        XCTAssertEqual(
            settings.workspaceBar.resolved(for: first).excludedBundleIDs,
            ["com.example.global"]
        )
        XCTAssertEqual(
            settings.workspaceBar.resolved(for: second).excludedBundleIDs,
            ["com.example.global"]
        )
    }

    private func monitor(displayId: CGDirectDisplayID, name: String, x: CGFloat) -> Monitor {
        Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: x, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: x, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: name
        )
    }

    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMWorkspaceBarExclusionSettingsTests-\(UUID().uuidString)", isDirectory: true)
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
