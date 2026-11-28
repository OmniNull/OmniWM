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
        let hidden = StatusMenuControl.bordersEnabled
        withStatusMenuSettings(source: "return {statusMenu = {hiddenControls = {'\(hidden.rawValue)'}}}") { settings, _ in
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
        let hidden = StatusMenuItem.appRules
        withStatusMenuSettings(source: "return {statusMenu = {hiddenMenuItems = {'\(hidden.rawValue)'}}}") { settings, _ in
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
                try SettingsLuauDocument(Data(contentsOf: fileURL)).export.statusMenu
            }

            var expected = SettingsExport.StatusMenu.defaults()
            expected.showMenuItems = !(try XCTUnwrap(expected.showMenuItems))
            settings.statusMenu.showMenuItems = try XCTUnwrap(expected.showMenuItems)
            XCTAssertEqual(try persisted(), expected)

            let control = StatusMenuControl.bordersEnabled.rawValue
            settings.statusMenu.setControl(control, isVisible: false)
            expected.hiddenControls = [control]
            XCTAssertNil(settings.configNotice)
            XCTAssertEqual(try persisted(), expected)

            expected.showControls = !(try XCTUnwrap(expected.showControls))
            settings.statusMenu.showControls = try XCTUnwrap(expected.showControls)
            XCTAssertEqual(try persisted(), expected)

            expected.showControlHelp = !(try XCTUnwrap(expected.showControlHelp))
            settings.statusMenu.showControlHelp = try XCTUnwrap(expected.showControlHelp)
            XCTAssertEqual(try persisted(), expected)

            let item = StatusMenuItem.appRules
            settings.statusMenu.setMenuItem(item, isVisible: false)
            expected.hiddenMenuItems = [item.rawValue]
            XCTAssertNil(settings.configNotice)
            XCTAssertEqual(try persisted(), expected)
        }
    }
}

final class StatusMenuSettingsLuauTests: XCTestCase {
    func testStatusMenuDefaultsRoundTrip() throws {
        let export = SettingsExport.defaults()
        let defaults = SettingsExport.StatusMenu.defaults()
        XCTAssertEqual(export.statusMenu, defaults)
        XCTAssertEqual(export.statusMenu.showControlHelp, defaults.showControlHelp)
        XCTAssertEqual(export.statusMenu.hiddenControls, defaults.hiddenControls)

        let data = try SettingsLuauDocument.initialSource(export)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("statusMenu = {"), text)
        XCTAssertEqual(try SettingsLuauFixture.decode(data).statusMenu, export.statusMenu)
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

        let data = try SettingsLuauDocument.initialSource(export)
        let decoded = try SettingsLuauFixture.decode(data)
        XCTAssertEqual(decoded.statusMenu, export.statusMenu)
        XCTAssertEqual(decoded.statusMenu.hiddenControls, controls)
        XCTAssertEqual(decoded.statusMenu.hiddenMenuItems, items)
        XCTAssertEqual(decoded.statusMenu.showControls, showControls)
    }

    func testRemovedAppMenuKeyIsUnknown() throws {
        let source = Data("return { statusMenu = { showAppMenu = true } }".utf8)
        XCTAssertThrowsError(try SettingsLuauDocument(source)) { error in
            XCTAssertTrue(error.localizedDescription.contains("statusMenu.showAppMenu"))
        }
    }

    func testOmittedStatusMenuTableUsesDefaults() throws {
        var fields = try SettingsLuauFixture.fields()
        fields.removeValue(forKey: "statusMenu")
        XCTAssertEqual(try SettingsLuauFixture.decode(SettingsLuauFixture.source(fields)).statusMenu, .defaults())
    }
}

@MainActor
private func withStatusMenuSettings(source: String? = nil, _ body: (SettingsStore, URL) throws -> Void) rethrows {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("OmniWMStatusMenuSettingsTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configDirectory = root.appendingPathComponent("config", isDirectory: true)
    if let source {
        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            try Data(source.utf8).write(to: configDirectory.appendingPathComponent(SettingsFilePersistence.fileName))
        } catch { return XCTFail("Could not create the settings fixture: \(error)") }
    }
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
    try body(settings, settings.settingsFileURL)
}
