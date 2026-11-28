// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

final class SystemStatsCommandTests: XCTestCase {
    func testToggleSystemStatsManifestResolves() throws {
        let descriptors = IPCAutomationManifest.commandDescriptors(matching: ["toggle-system-stats"])
        let descriptor = try XCTUnwrap(descriptors.first { $0.name == .presentation(.systemStats) })

        XCTAssertEqual(descriptor.commandWords, ["toggle-system-stats"])
        XCTAssertEqual(
            try IPCCommandRequest(name: descriptor.name, argumentValues: []),
            .init(.presentation(.systemStats))
        )
    }

    @MainActor
    func testRouterExecutesToggleSystemStats() {
        let controller = WMController(settings: makeSettingsStore())
        addTeardownBlock { @MainActor in
            controller.hasStartedServices = false
            controller.workspaceBarManager.cleanup()
            controller.layoutRefreshController.resetState()
            controller.mouseEventHandler.cleanup()
            controller.surfaceReconciler.cleanup()
            controller.axManager.cleanup()
            await controller.workspaceBarManager.flushShellForQuit()
        }
        let router = IPCCommandRouter(controller: controller, sessionToken: "test")

        XCTAssertEqual(router.handle(.init(.presentation(.systemStats))), .executed)
    }

    func testSystemStatsButtonSettingRoundTrips() throws {
        XCTAssertFalse(SettingsExport.defaults().workspaceBar.systemStatsButton)

        var export = SettingsExport.defaults()
        export.workspaceBar.systemStatsButton = true
        let data = try SettingsLuauDocument.initialSource(export)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("systemStatsButton = true"))
        XCTAssertTrue(try SettingsLuauFixture.decode(data).workspaceBar.systemStatsButton)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMSystemStatsTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { @MainActor in
            try FileManager.default.removeItem(at: root)
        }
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
