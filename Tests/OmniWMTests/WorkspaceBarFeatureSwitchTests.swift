// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class WorkspaceBarFeatureSwitchTests: XCTestCase {
    func testHoverPreviewSettingRoundTripsAndDefaultsWhenMissing() throws {
        var export = SettingsExport.defaults()
        XCTAssertTrue(export.workspaceBar.hoverPreviewsEnabled)

        export.workspaceBar.hoverPreviewsEnabled = false
        let data = try SettingsLuauDocument.initialSource(export)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("hoverPreviewsEnabled = false"))
        XCTAssertFalse(try SettingsLuauFixture.decode(data).workspaceBar.hoverPreviewsEnabled)

        let withoutKey = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("hoverPreviewsEnabled") }
            .joined(separator: "\n")
        XCTAssertTrue(try SettingsLuauFixture.decode(Data(withoutKey.utf8)).workspaceBar.hoverPreviewsEnabled)
    }

    @MainActor
    func testGlobalOffOverridesMonitorEnabledAndRestoresPreference() {
        let settings = makeSettingsStore()
        let monitor = Monitor(
            id: .init(displayId: 76_001),
            displayId: 76_001,
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 860),
            hasNotch: false,
            name: "Built-in"
        )
        settings.workspaceBar.enabled = false
        settings.workspaceBar.reserveLayoutSpace = true
        settings.workspaceBar.update(
            MonitorBarSettings(
                monitorName: monitor.name,
                monitorDisplayId: monitor.displayId,
                enabled: true,
                reserveLayoutSpace: true
            ),
            for: monitor
        )
        let controller = WMController(settings: settings)

        XCTAssertFalse(settings.workspaceBar.resolved(for: monitor).enabled)
        XCTAssertFalse(controller.workspaceBarRefreshIsEnabled)
        XCTAssertFalse(controller.isWorkspaceBarVisible(on: monitor))
        XCTAssertEqual(
            controller.insetWorkingFrame(for: monitor),
            CGRect(x: 5, y: 5, width: 1_430, height: 850)
        )

        settings.workspaceBar.enabled = true
        XCTAssertTrue(settings.workspaceBar.resolved(for: monitor).enabled)
        XCTAssertTrue(controller.workspaceBarRefreshIsEnabled)
        XCTAssertTrue(controller.isWorkspaceBarVisible(on: monitor))
        XCTAssertEqual(settings.workspaceBar.settings(for: monitor)?.enabled, true)

        settings.workspaceBar.enabled = false
        XCTAssertFalse(settings.workspaceBar.resolved(for: monitor).enabled)
        XCTAssertEqual(settings.workspaceBar.settings(for: monitor)?.enabled, true)
    }

    @MainActor
    func testHoverCaptureFollowsGlobalAndPreviewSwitches() {
        let settings = makeSettingsStore()
        settings.workspaceBar.enabled = false
        let controller = WMController(settings: settings)
        let manager = controller.workspaceBarManager

        controller.setWorkspaceBarEnabled(false)
        XCTAssertNil(manager.hoverPreview)

        controller.setWorkspaceBarEnabled(true)
        weak let firstPreview = manager.hoverPreview
        XCTAssertNotNil(firstPreview)

        settings.workspaceBar.hoverPreviewsEnabled = false
        controller.updateWorkspaceBarSettings()
        XCTAssertNil(manager.hoverPreview)
        XCTAssertNil(firstPreview)

        settings.workspaceBar.hoverPreviewsEnabled = true
        controller.updateWorkspaceBarSettings()
        weak let secondPreview = manager.hoverPreview
        XCTAssertNotNil(secondPreview)

        controller.setWorkspaceBarEnabled(false)
        XCTAssertNil(manager.hoverPreview)
        XCTAssertNil(secondPreview)
    }

    @MainActor
    func testRepeatedSetupKeepsThePermissionPromptCoordinator() throws {
        let settings = makeSettingsStore()
        settings.workspaceBar.enabled = false
        let controller = WMController(settings: settings)
        controller.setWorkspaceBarEnabled(false)
        let prompts = try XCTUnwrap(controller.workspaceBarManager.shellPermissionPrompts)

        controller.setWorkspaceBarEnabled(false)
        XCTAssertTrue(controller.workspaceBarManager.shellPermissionPrompts === prompts)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMWorkspaceBarFeatureSwitchTests-\(UUID().uuidString)", isDirectory: true)
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
