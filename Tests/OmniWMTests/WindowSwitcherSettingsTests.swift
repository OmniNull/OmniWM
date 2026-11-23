// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class WindowSwitcherSettingsTests: XCTestCase {
    func testRoundTripPersistsEnabledAndWorkspaceScope() throws {
        let scopes = WindowSwitcherScope.allCases
        for (index, shortcut) in WindowSwitcherShortcutScope.allCases.enumerated() {
            var settings = SettingsExport.defaults()
            settings.windowSwitcher.enabled = true
            settings.windowSwitcher.scope = scopes[index % scopes.count]
            settings.windowSwitcher.commandTab = .remembered
            settings.windowSwitcher.optionTab = shortcut
            settings.windowSwitcher.showFooter = false
            settings.windowSwitcher.order = .lastUsed
            let data = try SettingsLuauDocument.initialSource(settings)
            XCTAssertEqual(try SettingsLuauFixture.decode(data).windowSwitcher, settings.windowSwitcher)
        }
    }

    func testVisibleWorkspacesUsesItsDocumentedLuauValue() throws {
        var settings = SettingsExport.defaults()
        settings.windowSwitcher.scope = .visibleWorkspaces
        let encoded = String(decoding: try SettingsLuauDocument.initialSource(settings), as: UTF8.self)
        XCTAssertTrue(encoded.contains("scope = \"visibleWorkspaces\""))
    }

    func testNewConfigurationDefaultsToSeparateWorkspaceShortcuts() {
        let settings = SettingsExport.defaults().windowSwitcher
        XCTAssertEqual(settings.commandTab, .activeWorkspace)
        XCTAssertEqual(settings.optionTab, .allWorkspaces)
        XCTAssertTrue(settings.showFooter)
        XCTAssertEqual(settings.order, .omniLayout)
    }

    func testExistingSwitcherConfigurationDefaultsToLayoutOrder() throws {
        var settings = SettingsExport.defaults()
        settings.windowSwitcher.enabled = true
        settings.windowSwitcher.commandTab = .remembered
        let encoded = try SettingsLuauDocument.initialSource(settings)
        let orderLine = "order = \"\(WindowSwitcherOrder.omniLayout.rawValue)\",\n"
        let legacy = String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: orderLine, with: "")
        XCTAssertNotEqual(legacy, String(decoding: encoded, as: UTF8.self))
        let decoded = try SettingsLuauFixture.decode(Data(legacy.utf8))
        XCTAssertEqual(decoded.windowSwitcher, settings.windowSwitcher)
    }

    func testExistingConfigurationDoesNotOptIntoReplacingCommandTab() throws {
        var fields = try SettingsLuauFixture.fields()
        XCTAssertNotNil(fields.removeValue(forKey: "windowSwitcher"))
        let decoded = try SettingsLuauFixture.decode(SettingsLuauFixture.source(fields))
        XCTAssertFalse(decoded.windowSwitcher.enabled)
        XCTAssertEqual(decoded.windowSwitcher.scope, .allWorkspaces)
    }

    @MainActor
    func testSettingsOwnerImportsAndExportsScope() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: directory.appendingPathComponent("config"), startWatching: false, deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: directory.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        var export = SettingsExport.defaults()
        export.windowSwitcher.enabled = true
        export.windowSwitcher.scope = .activeWorkspace
        export.windowSwitcher.commandTab = .disabled
        export.windowSwitcher.optionTab = .remembered
        export.windowSwitcher.showFooter = false
        export.windowSwitcher.order = .lastUsed
        settings.applyExport(export)
        XCTAssertEqual(settings.windowSwitcher.export(), export.windowSwitcher)
    }

    @MainActor
    func testSwitcherFocusLeasePreventsMouseFocusUntilDismissed() {
        let policy = FocusPolicyEngine()
        policy.screenshotSelectionActiveProvider = { false }
        policy.beginLease(owner: .windowSwitcher, reason: "window_switcher", duration: nil)
        XCTAssertFalse(policy.evaluate(.focusFollowsMouse).allowsFocusChange)
        policy.endLease(owner: .windowSwitcher)
        XCTAssertTrue(policy.evaluate(.focusFollowsMouse).allowsFocusChange)
    }
}
