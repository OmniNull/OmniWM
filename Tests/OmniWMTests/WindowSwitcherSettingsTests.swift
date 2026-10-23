// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class WindowSwitcherSettingsTests: XCTestCase {
    func testRoundTripPersistsEnabledAndWorkspaceScope() throws {
        var settings = SettingsExport.defaults()
        settings.windowSwitcher.enabled = true
        settings.windowSwitcher.scope = .activeWorkspace
        settings.windowSwitcher.commandTab = .remembered
        settings.windowSwitcher.optionTab = .disabled
        settings.windowSwitcher.showFooter = false
        settings.windowSwitcher.order = .lastUsed
        let data = try SettingsTOMLCodec.encode(settings)
        XCTAssertEqual(try SettingsTOMLCodec.decode(data).windowSwitcher, settings.windowSwitcher)
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
        let encoded = try SettingsTOMLCodec.encode(settings)
        let legacy = String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "order = \"omniLayout\"\n", with: "")
        XCTAssertNotEqual(legacy, String(decoding: encoded, as: UTF8.self))
        let decoded = try SettingsTOMLCodec.decode(Data(legacy.utf8))
        XCTAssertEqual(decoded.windowSwitcher, settings.windowSwitcher)
    }

    func testExistingConfigurationDoesNotOptIntoReplacingCommandTab() throws {
        let encoded = try SettingsTOMLCodec.encode(SettingsExport.defaults())
        let lines = String(decoding: encoded, as: UTF8.self).components(separatedBy: "\n")
        var inSwitcherSection = false
        let legacy = lines.filter { line in
            if line.hasPrefix("[") { inSwitcherSection = line == "[windowSwitcher]" }
            return !inSwitcherSection
        }.joined(separator: "\n")
        let decoded = try SettingsTOMLCodec.decode(Data(legacy.utf8))
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
