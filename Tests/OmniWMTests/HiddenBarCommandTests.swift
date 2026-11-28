// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

final class HiddenBarCommandTests: XCTestCase {
    func testHiddenBarPanelManifestResolves() throws {
        let descriptors = IPCAutomationManifest.commandDescriptors(matching: ["hidden-bar", "panel"])
        let descriptor = try XCTUnwrap(descriptors.first { $0.name == .presentation(.hiddenBar) })

        XCTAssertEqual(descriptor.commandWords, ["hidden-bar", "panel"])
        XCTAssertEqual(descriptor.path, "command hidden-bar panel")
        XCTAssertEqual(
            try IPCCommandRequest(name: descriptor.name, argumentValues: []),
            .init(.presentation(.hiddenBar))
        )
    }

    @MainActor
    func testRouterExecutesHiddenBarPanel() {
        let controller = WMController(settings: makeSettingsStore())
        defer { controller.hiddenBarController.dismissPanel() }
        let router = IPCCommandRouter(controller: controller, sessionToken: "test")

        XCTAssertEqual(router.handle(.init(.presentation(.hiddenBar))), .executed)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMHiddenBarCommandTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
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
