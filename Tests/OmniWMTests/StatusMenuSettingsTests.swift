// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import SwiftUI
import XCTest

@MainActor
final class StatusMenuSettingsTests: XCTestCase {
    func testDefaultsMatchTheExportedChoices() throws {
        let settings = StatusMenuSettings()
        let defaults = SettingsExport.StatusMenu.defaults()
        let showControls = try XCTUnwrap(defaults.showControls)
        let showMenuItems = try XCTUnwrap(defaults.showMenuItems)
        let hiddenControls = Set(try XCTUnwrap(defaults.hiddenControls))
        let hiddenMenuItems = Set(try XCTUnwrap(defaults.hiddenMenuItems))
        XCTAssertEqual(settings.showControlHelp, try XCTUnwrap(defaults.showControlHelp))
        XCTAssertEqual(settings.showControls, showControls)
        XCTAssertEqual(settings.showMenuItems, showMenuItems)
        XCTAssertEqual(settings.hiddenControls, hiddenControls)
        XCTAssertEqual(settings.hiddenMenuItems, hiddenMenuItems)
        for control in StatusMenuControl.allCases {
            XCTAssertEqual(
                settings.isControlVisible(control.rawValue),
                showControls && !hiddenControls.contains(control.rawValue)
            )
        }
        for item in StatusMenuItem.allCases {
            XCTAssertEqual(settings.isMenuItemVisible(item), showMenuItems && !hiddenMenuItems.contains(item.rawValue))
        }
    }

    func testControlsMasterToggleKeepsPerTileChoices() {
        let settings = StatusMenuSettings()
        settings.setControl(StatusMenuControl.bordersEnabled.rawValue, isVisible: false)
        settings.setControl(StatusMenuControl.workspaceBarEnabled.rawValue, isVisible: true)
        settings.showControls = false
        XCTAssertTrue(StatusMenuControl.allCases.allSatisfy { !settings.isControlVisible($0.rawValue) })
        XCTAssertEqual(settings.hiddenControls, [StatusMenuControl.bordersEnabled.rawValue])

        settings.showControls = true
        XCTAssertFalse(settings.isControlVisible(StatusMenuControl.bordersEnabled.rawValue))
        XCTAssertTrue(settings.isControlVisible(StatusMenuControl.workspaceBarEnabled.rawValue))
    }

    func testMenuItemsMasterToggleKeepsPerItemChoices() {
        let settings = StatusMenuSettings()
        settings.setMenuItem(.appRules, isVisible: false)
        settings.setMenuItem(.settings, isVisible: true)
        settings.setMenuItem(.sponsors, isVisible: true)
        settings.showMenuItems = false
        XCTAssertTrue(StatusMenuItem.allCases.allSatisfy { !settings.isMenuItemVisible($0) })

        settings.showMenuItems = true
        XCTAssertFalse(settings.isMenuItemVisible(.appRules))
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
        settings.showControls = true
        settings.setControl(StatusMenuControl.bordersEnabled.rawValue, isVisible: true)
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
        let controls = [StatusMenuControl.bordersEnabled.rawValue, StatusMenuControl.hiddenBarEnabled.rawValue]
        let items = [StatusMenuItem.sponsors.rawValue, StatusMenuItem.appRules.rawValue]
        settings.apply(
            SettingsExport.StatusMenu(
                showControls: false,
                showControlHelp: false,
                showMenuItems: false,
                hiddenControls: [" \(controls[0]) ", "", controls[1]],
                hiddenMenuItems: [" \(items[0]) ", "", items[1]]
            )
        )
        XCTAssertFalse(settings.showControls)
        XCTAssertFalse(settings.showControlHelp)
        XCTAssertFalse(settings.showMenuItems)
        XCTAssertEqual(settings.hiddenMenuItems.sorted(), items.sorted())
        XCTAssertEqual(settings.hiddenControls.sorted(), controls.sorted())
    }

    func testApplyFallsBackToDefaultsForMissingValues() throws {
        let settings = StatusMenuSettings()
        let defaults = SettingsExport.StatusMenu.defaults()
        settings.showControls = !(try XCTUnwrap(defaults.showControls))
        settings.showControlHelp = !(try XCTUnwrap(defaults.showControlHelp))
        settings.showMenuItems = !(try XCTUnwrap(defaults.showMenuItems))
        settings.setControl(StatusMenuControl.bordersEnabled.rawValue, isVisible: false)
        settings.setMenuItem(.appRules, isVisible: false)
        settings.apply(
            SettingsExport.StatusMenu(
                showControls: nil,
                showControlHelp: nil,
                showMenuItems: nil,
                hiddenControls: nil,
                hiddenMenuItems: nil
            )
        )
        XCTAssertEqual(settings.showControls, try XCTUnwrap(defaults.showControls))
        XCTAssertEqual(settings.showControlHelp, try XCTUnwrap(defaults.showControlHelp))
        XCTAssertEqual(settings.showMenuItems, try XCTUnwrap(defaults.showMenuItems))
        XCTAssertEqual(settings.hiddenControls, Set(try XCTUnwrap(defaults.hiddenControls)))
        XCTAssertEqual(settings.hiddenMenuItems, Set(try XCTUnwrap(defaults.hiddenMenuItems)))
    }

    func testDisabledControlSwitchKeepsItsStoredChoice() {
        withStatusMenuSettings { settings, _ in
            let hidden = StatusMenuControl.bordersEnabled
            let shown = StatusMenuControl.workspaceBarEnabled
            let featureState = settings.borders.enabled
            settings.statusMenu.setControl(hidden.rawValue, isVisible: false)
            settings.statusMenu.setControl(shown.rawValue, isVisible: true)
            let tab = StatusMenuSettingsTab(settings: settings)
            let hiddenBinding = tab.visibilityBinding(for: hidden)
            let shownBinding = tab.visibilityBinding(for: shown)

            settings.statusMenu.showControls = false
            XCTAssertFalse(settings.statusMenu.isControlVisible(shown.rawValue))
            XCTAssertFalse(hiddenBinding.wrappedValue)
            XCTAssertTrue(shownBinding.wrappedValue)

            settings.statusMenu.showControls = true
            XCTAssertFalse(settings.statusMenu.isControlVisible(hidden.rawValue))
            XCTAssertTrue(settings.statusMenu.isControlVisible(shown.rawValue))
            XCTAssertFalse(hiddenBinding.wrappedValue)
            XCTAssertTrue(shownBinding.wrappedValue)
            XCTAssertEqual(settings.borders.enabled, featureState)
        }
    }

    func testDisabledMenuItemSwitchKeepsItsStoredChoice() {
        withStatusMenuSettings { settings, _ in
            let hidden = StatusMenuItem.appRules
            let shown = StatusMenuItem.settings
            settings.statusMenu.setMenuItem(hidden, isVisible: false)
            settings.statusMenu.setMenuItem(shown, isVisible: true)
            let tab = StatusMenuSettingsTab(settings: settings)
            let hiddenBinding = tab.menuItemVisibilityBinding(for: hidden)
            let shownBinding = tab.menuItemVisibilityBinding(for: shown)

            settings.statusMenu.showMenuItems = false
            XCTAssertFalse(settings.statusMenu.isMenuItemVisible(shown))
            XCTAssertFalse(hiddenBinding.wrappedValue)
            XCTAssertTrue(shownBinding.wrappedValue)

            settings.statusMenu.showMenuItems = true
            XCTAssertFalse(settings.statusMenu.isMenuItemVisible(hidden))
            XCTAssertTrue(settings.statusMenu.isMenuItemVisible(shown))
            XCTAssertFalse(hiddenBinding.wrappedValue)
            XCTAssertTrue(shownBinding.wrappedValue)
        }
    }
}

@MainActor
final class StatusMenuSettingsPersistenceTests: XCTestCase {
    func testChangingStatusMenuSettingsSchedulesASave() throws {
        try withStatusMenuSettings { settings, fileURL in
            func persisted() throws -> SettingsExport.StatusMenu {
                try SettingsTOMLCodec.decode(Data(contentsOf: fileURL)).statusMenu
            }

            var expected = SettingsExport.StatusMenu.defaults()
            expected.showMenuItems = !(try XCTUnwrap(expected.showMenuItems))
            settings.statusMenu.showMenuItems = try XCTUnwrap(expected.showMenuItems)
            XCTAssertEqual(try persisted(), expected)

            let control = StatusMenuControl.bordersEnabled.rawValue
            expected.hiddenControls = [control]
            settings.statusMenu.setControl(control, isVisible: false)
            XCTAssertEqual(try persisted(), expected)

            expected.showControls = !(try XCTUnwrap(expected.showControls))
            settings.statusMenu.showControls = try XCTUnwrap(expected.showControls)
            XCTAssertEqual(try persisted(), expected)

            expected.showControlHelp = !(try XCTUnwrap(expected.showControlHelp))
            settings.statusMenu.showControlHelp = try XCTUnwrap(expected.showControlHelp)
            XCTAssertEqual(try persisted(), expected)

            let item = StatusMenuItem.appRules
            expected.hiddenMenuItems = [item.rawValue]
            settings.statusMenu.setMenuItem(item, isVisible: false)
            XCTAssertEqual(try persisted(), expected)
        }
    }
}

final class StatusMenuSettingsTOMLTests: XCTestCase {
    func testStatusMenuDefaultsRoundTrip() throws {
        let export = SettingsExport.defaults()
        let defaults = SettingsExport.StatusMenu.defaults()
        XCTAssertEqual(export.statusMenu, defaults)
        XCTAssertEqual(export.statusMenu.showControlHelp, defaults.showControlHelp)
        XCTAssertEqual(export.statusMenu.hiddenControls, defaults.hiddenControls)

        let data = try SettingsTOMLCodec.encode(export)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("[statusMenu]"), text)
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).statusMenu, export.statusMenu)
        XCTAssertEqual(SettingsTOMLCodec.unknownKeyPaths(in: data), [])
    }

    func testHiddenControlsRoundTrip() throws {
        var export = SettingsExport.defaults()
        let defaults = SettingsExport.StatusMenu.defaults()
        let showControls = !(try XCTUnwrap(defaults.showControls))
        let controls = [StatusMenuControl.bordersEnabled.rawValue, StatusMenuControl.hiddenBarEnabled.rawValue]
        let items = [StatusMenuItem.diagnostics.rawValue, StatusMenuItem.sponsors.rawValue]
        export.statusMenu.showControls = showControls
        export.statusMenu.hiddenControls = controls
        export.statusMenu.hiddenMenuItems = items

        let data = try SettingsTOMLCodec.encode(export)
        let decoded = try SettingsTOMLCodec.decode(data)
        XCTAssertEqual(decoded.statusMenu, export.statusMenu)
        XCTAssertEqual(decoded.statusMenu.hiddenControls, controls)
        XCTAssertEqual(decoded.statusMenu.hiddenMenuItems, items)
        XCTAssertEqual(decoded.statusMenu.showControls, showControls)
    }

    func testRemovedAppMenuKeyIsUnknown() throws {
        let key = "showAppMenu"
        let table = "statusMenu"
        let canonical = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let input = canonical.replacingOccurrences(of: "[\(table)]", with: "[\(table)]\n\(key) = true")
        XCTAssertEqual(SettingsTOMLCodec.unknownKeyPaths(in: Data(input.utf8)), ["\(table).\(key)"])
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

@MainActor
private func withStatusMenuSettings(_ body: (SettingsStore, URL) throws -> Void) rethrows {
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
    try body(settings, configDirectory.appendingPathComponent("settings.toml"))
}
