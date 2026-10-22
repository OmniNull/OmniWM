// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowTilingSettingsProbeTests: XCTestCase {
    private final class Preferences {
        var values: [String: Any] = [:]
        var synchronizedDomains: [String] = []
        var openedURLs: [URL] = []
    }

    private func makeProbe(_ preferences: Preferences) -> WindowTilingSettingsProbe {
        WindowTilingSettingsProbe(
            preferenceReader: { key, domain in
                domain == "com.apple.WindowManager" ? preferences.values[key] : nil
            },
            domainSynchronizer: { preferences.synchronizedDomains.append($0) },
            urlOpener: { preferences.openedURLs.append($0) }
        )
    }

    func testEachSettingMapsToItsWindowManagerKey() {
        XCTAssertEqual(WindowTilingSettingsProbe.Setting.screenEdges.preferenceKey, "EnableTilingByEdgeDrag")
        XCTAssertEqual(WindowTilingSettingsProbe.Setting.menuBar.preferenceKey, "EnableTopTilingByEdgeDrag")
        XCTAssertEqual(WindowTilingSettingsProbe.Setting.optionKey.preferenceKey, "EnableTilingOptionAccelerator")
    }

    func testMissingKeysCountAsMacOSDefaultsAndAreReported() {
        let preferences = Preferences()
        let probe = makeProbe(preferences)

        probe.refresh()

        XCTAssertEqual(probe.enabledSettings, WindowTilingSettingsProbe.Setting.allCases)
        XCTAssertEqual(preferences.synchronizedDomains, ["com.apple.WindowManager"])
    }

    func testOnlySettingsThatAreOnAreReported() {
        let preferences = Preferences()
        preferences.values = [
            "EnableTilingByEdgeDrag": NSNumber(value: 1),
            "EnableTopTilingByEdgeDrag": NSNumber(value: false),
            "EnableTilingOptionAccelerator": NSNumber(value: 0)
        ]
        let probe = makeProbe(preferences)

        probe.refresh()

        XCTAssertEqual(probe.enabledSettings, [.screenEdges])
    }

    func testTheReportClearsOnceTheSettingsAreTurnedOff() {
        let preferences = Preferences()
        preferences.values = ["EnableTilingByEdgeDrag": NSNumber(value: true)]
        let probe = makeProbe(preferences)
        probe.refresh()
        XCTAssertFalse(probe.enabledSettings.isEmpty)

        preferences.values = [
            "EnableTilingByEdgeDrag": NSNumber(value: false),
            "EnableTopTilingByEdgeDrag": NSNumber(value: false),
            "EnableTilingOptionAccelerator": NSNumber(value: false)
        ]
        probe.refresh()

        XCTAssertTrue(probe.enabledSettings.isEmpty)
    }

    func testOpensDesktopAndDockSettings() {
        let preferences = Preferences()
        let probe = makeProbe(preferences)

        probe.openDesktopAndDockSettings()

        XCTAssertEqual(
            preferences.openedURLs.map(\.absoluteString),
            ["x-apple.systempreferences:com.apple.Desktop-Settings.extension"]
        )
    }
}
