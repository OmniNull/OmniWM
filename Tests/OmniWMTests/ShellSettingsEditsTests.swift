// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class ShellSettingsEditsTests: XCTestCase {
    @MainActor
    func testMonitorEditsAndResetPublishWhileTheGlobalBarIsDisabled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMShellSettingsEditsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(
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
        settings.workspaceBar.enabled = false
        let controller = WMController(settings: settings)
        controller.workspaceBarManager.setup(controller: controller, settings: settings)
        let directory = ShellWidgetHost.shellDirectory(in: settings.settingsFileURL.deletingLastPathComponent())
        let profile = directory.appendingPathComponent("look", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try """
        [workspaceBar]
        position = "left"
        height = 60
        [hiddenBar]
        enabled = false
        """.write(to: profile.appendingPathComponent("shell.toml"), atomically: true, encoding: .utf8)
        try """
        profile = "look"
        [profiles.other.workspaceBar]
        height = 90
        """.write(to: directory.appendingPathComponent("shell.toml"), atomically: true, encoding: .utf8)
        let monitor = Monitor(
            id: .init(displayId: 77_001),
            displayId: 77_001,
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 860),
            hasNotch: false,
            name: "Display"
        )

        XCTAssertNil(controller.workspaceBarManager.shellHost)
        let originalFile = try Data(contentsOf: directory.appendingPathComponent("shell.toml"))
        try await controller.workspaceBarManager.shellConfiguration.refresh()
        XCTAssertEqual(settings.workspaceBar.profileOverride?.profile, "look")
        XCTAssertEqual(settings.workspaceBar.resolved(for: monitor).position, .left)
        XCTAssertEqual(settings.workspaceBar.resolved(for: monitor).height, 60)
        XCTAssertFalse(settings.hiddenBar.resolvedEnabled)
        XCTAssertNil(controller.workspaceBarManager.shellHost)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("shell.toml")), originalFile)
        try await ShellSettingsEdits.updateMonitor(monitor, settings: settings, controller: controller) {
            $0.enabled = true
            $0.position = .bottom
            $0.height = 80
        }
        XCTAssertEqual(settings.workspaceBar.profileOverride?.profile, "look")
        XCTAssertEqual(settings.workspaceBar.resolved(for: monitor).position, .bottom)
        XCTAssertEqual(settings.workspaceBar.resolved(for: monitor).height, 80)
        XCTAssertFalse(settings.workspaceBar.resolved(for: monitor).enabled)
        XCTAssertEqual(settings.hiddenBar.profileOverride?.enabled, false)
        let stored = try XCTUnwrap(ShellConfig.load(shellDirectory: directory)?.barOverride)
        XCTAssertEqual(MonitorSettingsStore.get(for: monitor, in: stored.monitorOverrides)?.height, 80)

        try await ShellSettingsEdits.updateMonitor(monitor, settings: settings, controller: controller, change: nil)
        XCTAssertTrue(settings.workspaceBar.profileOverride?.monitorOverrides.isEmpty == true)
        XCTAssertEqual(settings.workspaceBar.resolved(for: monitor).position, .left)
        XCTAssertEqual(settings.workspaceBar.resolved(for: monitor).height, 60)
        XCTAssertFalse(settings.workspaceBar.enabled)
        XCTAssertFalse(settings.workspaceBar.resolved(for: monitor).enabled)
        XCTAssertNil(controller.workspaceBarManager.shellHost)
        let saved = try String(contentsOf: directory.appendingPathComponent("shell.toml"), encoding: .utf8)
        XCTAssertFalse(try ShellTOMLText.contains(["profiles", "look", "monitorBarOverrides"], in: saved))
        XCTAssertTrue(try ShellTOMLText.contains(["profiles", "other", "workspaceBar", "height"], in: saved))
    }
}
