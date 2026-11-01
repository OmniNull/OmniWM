// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class RelaunchPresentationTests: XCTestCase {
    func testReopenShowsSettingsOnceReadyAndWaitsForLaunchBeforeThat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OmniWMRelaunch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeState = RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false)
        runtimeState.welcomePresented = true
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config"),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: runtimeState,
            autosaveEnabled: false
        )
        let controller = WMController(
            settings: settings,
            clipboardHistoryDirectory: root.appendingPathComponent("clipboard"),
            diagnosticsDirectory: root.appendingPathComponent("diagnostics"),
            ownedWindowRegistry: OwnedWindowRegistry()
        )
        let previousBootstrap = AppDelegate.sharedBootstrap
        defer { AppDelegate.sharedBootstrap = previousBootstrap }
        let bootstrap = AppBootstrapState()
        AppDelegate.sharedBootstrap = bootstrap

        let delegate = AppDelegate()
        var presentations = 0
        delegate.showSettings = { presentations += 1 }

        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertEqual(presentations, 0)

        bootstrap.settings = settings
        bootstrap.controller = controller
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        XCTAssertEqual(presentations, 0)

        delegate.launchOverlayDidFinish(runtimeState: runtimeState, controller: controller)
        XCTAssertEqual(presentations, 1)

        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        XCTAssertEqual(presentations, 2)
    }
}
