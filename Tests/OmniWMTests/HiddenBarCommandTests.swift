// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

final class HiddenBarCommandTests: XCTestCase {
    func testHiddenBarPanelSpecRegistered() throws {
        let spec = try XCTUnwrap(ActionCatalog.spec(for: .presentation(.hiddenBar)))

        XCTAssertEqual(spec.id, "toggleHiddenBarPanel")
        XCTAssertEqual(spec.title, "Toggle Hidden Icons Panel")
        XCTAssertEqual(spec.layoutCompatibility, .shared)
        XCTAssertEqual(spec.defaultBinding, .unassigned)
        XCTAssertEqual(spec.ipcCommandName, .presentation(.hiddenBar))
        XCTAssertNotNil(spec.ipcDescriptor)
    }

    func testHiddenBarPanelNameMapping() {
        XCTAssertEqual(IPCCommandRequest.presentation(.hiddenBar).name, .presentation(.hiddenBar))
    }

    func testHiddenBarPanelJSONRoundTrip() throws {
        let data = try JSONEncoder().encode(IPCCommandRequest.presentation(.hiddenBar))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["name"] as? String, "hidden-bar-panel")
        XCTAssertEqual(try JSONDecoder().decode(IPCCommandRequest.self, from: data), .presentation(.hiddenBar))
    }

    func testHiddenBarPanelManifestResolves() throws {
        let descriptors = IPCAutomationManifest.commandDescriptors(matching: ["hidden-bar", "panel"])
        let descriptor = try XCTUnwrap(descriptors.first { $0.name == .presentation(.hiddenBar) })

        XCTAssertEqual(descriptor.commandWords, ["hidden-bar", "panel"])
        XCTAssertEqual(descriptor.path, "command hidden-bar panel")
        XCTAssertEqual(try IPCCommandRequest(name: descriptor.name, argumentValues: []), .presentation(.hiddenBar))
    }

    @MainActor
    func testRouterExecutesHiddenBarPanel() {
        let controller = WMController(settings: makeSettingsStore())
        defer { controller.hiddenBarController.dismissPanel() }
        let router = IPCCommandRouter(controller: controller, sessionToken: "test")

        XCTAssertEqual(router.handle(.presentation(.hiddenBar)), .executed)
    }

    @MainActor
    private func makeSettingsStore() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMHiddenBarCommandTests-\(UUID().uuidString)", isDirectory: true)
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
