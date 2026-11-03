// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class StatusMenuSettingsTests: XCTestCase {
    func testDefaultsShowAppMenuHelpAndEveryControl() {
        let settings = StatusMenuSettings()
        XCTAssertTrue(settings.showAppMenu)
        XCTAssertTrue(settings.showControlHelp)
        XCTAssertTrue(settings.showControls)
        XCTAssertTrue(settings.showMenuItems)
        XCTAssertTrue(settings.hiddenControls.isEmpty)
        XCTAssertTrue(settings.hiddenMenuItems.isEmpty)
        XCTAssertTrue(StatusMenuControl.allCases.allSatisfy { settings.isControlVisible($0.rawValue) })
        XCTAssertTrue(StatusMenuItem.allCases.allSatisfy { settings.isMenuItemVisible($0) })
    }

    func testControlsMasterToggleKeepsPerTileChoices() {
        let settings = StatusMenuSettings()
        settings.setControl(StatusMenuControl.bordersEnabled.rawValue, isVisible: false)
        settings.showControls = false
        XCTAssertTrue(StatusMenuControl.allCases.allSatisfy { !settings.isControlVisible($0.rawValue) })
        XCTAssertEqual(settings.hiddenControls, [StatusMenuControl.bordersEnabled.rawValue])

        settings.showControls = true
        XCTAssertFalse(settings.isControlVisible(StatusMenuControl.bordersEnabled.rawValue))
        XCTAssertTrue(settings.isControlVisible(StatusMenuControl.workspaceBarEnabled.rawValue))
    }

    func testMenuItemsMasterToggleKeepsPerItemChoices() {
        let settings = StatusMenuSettings()
        settings.setMenuItem(.reportBug, isVisible: false)
        settings.showMenuItems = false
        XCTAssertTrue(StatusMenuItem.allCases.allSatisfy { !settings.isMenuItemVisible($0) })

        settings.showMenuItems = true
        XCTAssertFalse(settings.isMenuItemVisible(.reportBug))
        XCTAssertTrue(settings.isMenuItemVisible(.settings))
        XCTAssertTrue(settings.isMenuItemVisible(.sponsors))
    }

    func testHidingEveryMenuItemCollapsesTheSection() {
        let settings = StatusMenuSettings()
        for item in StatusMenuItem.allCases {
            settings.setMenuItem(item, isVisible: false)
        }
        XCTAssertTrue(StatusMenuItem.allCases.allSatisfy { !settings.isMenuItemVisible($0) })
        XCTAssertEqual(settings.hiddenMenuItems.count, StatusMenuItem.allCases.count)
    }

    func testHidingAControlKeepsFeatureStateAndPersistsRawID() {
        let settings = StatusMenuSettings()
        settings.setControl(StatusMenuControl.mouseWarpEnabled.rawValue, isVisible: false)
        XCTAssertFalse(settings.isControlVisible(StatusMenuControl.mouseWarpEnabled.rawValue))
        XCTAssertTrue(settings.isControlVisible(StatusMenuControl.bordersEnabled.rawValue))
        XCTAssertEqual(settings.export().hiddenControls, [StatusMenuControl.mouseWarpEnabled.rawValue])

        settings.setControl(StatusMenuControl.mouseWarpEnabled.rawValue, isVisible: true)
        XCTAssertTrue(settings.isControlVisible(StatusMenuControl.mouseWarpEnabled.rawValue))
        XCTAssertTrue(settings.export().hiddenControls?.isEmpty ?? false)
    }

    func testApplyKeepsOnlyNonEmptyHiddenControls() {
        let settings = StatusMenuSettings()
        settings.apply(
            SettingsExport.StatusMenu(
                showControls: false,
                showAppMenu: false,
                showControlHelp: false,
                showMenuItems: false,
                hiddenControls: [" bordersEnabled ", "", "hiddenBarEnabled"],
                hiddenMenuItems: [" sponsors ", "", "reportBug"]
            )
        )
        XCTAssertFalse(settings.showControls)
        XCTAssertFalse(settings.showAppMenu)
        XCTAssertFalse(settings.showControlHelp)
        XCTAssertFalse(settings.showMenuItems)
        XCTAssertEqual(settings.hiddenMenuItems.sorted(), ["reportBug", "sponsors"])
        XCTAssertEqual(
            settings.hiddenControls.sorted(),
            [StatusMenuControl.bordersEnabled.rawValue, StatusMenuControl.hiddenBarEnabled.rawValue].sorted()
        )
    }

    func testApplyFallsBackToDefaultsForMissingValues() {
        let settings = StatusMenuSettings()
        settings.showAppMenu = false
        settings.showControlHelp = false
        settings.apply(
            SettingsExport.StatusMenu(
                showControls: nil,
                showAppMenu: nil,
                showControlHelp: nil,
                showMenuItems: nil,
                hiddenControls: nil,
                hiddenMenuItems: nil
            )
        )
        XCTAssertTrue(settings.showControls)
        XCTAssertTrue(settings.showAppMenu)
        XCTAssertTrue(settings.showControlHelp)
        XCTAssertTrue(settings.showMenuItems)
        XCTAssertTrue(settings.hiddenControls.isEmpty)
    }
}

@MainActor
final class StatusMenuSettingsPersistenceTests: XCTestCase {
    func testChangingStatusMenuSettingsSchedulesASave() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMStatusMenuSettingsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: configDirectory,
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: true
        )

        settings.statusMenu.showMenuItems = false
        settings.statusMenu.setControl(StatusMenuControl.bordersEnabled.rawValue, isVisible: false)
        settings.flushNow()

        let persisted = try SettingsTOMLCodec.decode(
            Data(contentsOf: configDirectory.appendingPathComponent("settings.toml"))
        ).statusMenu
        XCTAssertEqual(persisted.showMenuItems, false)
        XCTAssertEqual(persisted.hiddenControls, [StatusMenuControl.bordersEnabled.rawValue])
    }
}

final class StatusMenuSettingsTOMLTests: XCTestCase {
    func testStatusMenuDefaultsRoundTrip() throws {
        let export = SettingsExport.defaults()
        XCTAssertEqual(export.statusMenu.showAppMenu, true)
        XCTAssertEqual(export.statusMenu.showControlHelp, true)
        XCTAssertEqual(export.statusMenu.hiddenControls, [])

        let data = try SettingsTOMLCodec.encode(export)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("[statusMenu]"), text)
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).statusMenu, export.statusMenu)
        XCTAssertEqual(SettingsTOMLCodec.unknownKeyPaths(in: data), [])
    }

    func testHiddenControlsRoundTrip() throws {
        var export = SettingsExport.defaults()
        export.statusMenu.showAppMenu = false
        export.statusMenu.showControls = false
        export.statusMenu.hiddenControls = ["bordersEnabled", "hiddenBarEnabled"]
        export.statusMenu.hiddenMenuItems = ["diagnostics", "sponsors"]

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertEqual(decoded.statusMenu, export.statusMenu)
        XCTAssertEqual(decoded.statusMenu.hiddenControls ?? [], ["bordersEnabled", "hiddenBarEnabled"])
        XCTAssertEqual(decoded.statusMenu.hiddenMenuItems ?? [], ["diagnostics", "sponsors"])
        XCTAssertEqual(decoded.statusMenu.showControls, false)
    }

    func testOmittedStatusMenuTableUsesDefaultsWithoutMigration() throws {
        let canonical = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        var lines = canonical.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0 == "[statusMenu]" }) else {
            return XCTFail("canonical config is missing the statusMenu table")
        }
        var end = start + 1
        while end < lines.count, !lines[end].hasPrefix("[") {
            end += 1
        }
        lines.removeSubrange(start ..< end)

        let result = try SettingsTOMLCodec.decodeForLoad(Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(result.export.statusMenu, SettingsExport.StatusMenu.defaults())
        XCTAssertNil(result.migration)
        XCTAssertNil(result.migratedData)
    }
}
