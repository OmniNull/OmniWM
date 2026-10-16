// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class DisplayQueryFieldsTests: XCTestCase {
    func testDisplaysReportTheirUUIDNotchMenuBarAndReservedInsetsOnlyWhenAsked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
        let monitor = Monitor(
            id: .init(displayId: 7),
            displayId: 7,
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            hasNotch: true,
            notchRange: 662 ... 850,
            name: "Built-in",
            displayUUID: "37D8832A-2D66-02CA-B9F7-8F30A301B230"
        )
        let controller = WMController(settings: settings)
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let router = IPCQueryRouter(controller: controller, appVersion: nil, sessionToken: "display-fields")
        let fields = ["uuid", "notch", "menu-bar-height", "bar-frames", "reserved-insets"]
        XCTAssertTrue(Set(fields).isSubset(of: IPCAutomationManifest.displayFieldCatalog))

        let display = try XCTUnwrap(
            router.displaysResult(IPCQueryRequest(name: .displays, fields: ["id"] + fields)).displays.first
        )
        XCTAssertEqual(display.uuid, "37D8832A-2D66-02CA-B9F7-8F30A301B230")
        XCTAssertEqual(display.notch, IPCSpan(start: 662, end: 850))
        XCTAssertEqual(display.menuBarHeight, 38)
        XCTAssertEqual(display.barFrames, [])
        XCTAssertEqual(display.reservedInsets, controller.workspaceBarReservedInsets(for: monitor).ipcInsets)

        let plain = try XCTUnwrap(router.displaysResult(IPCQueryRequest(name: .displays, fields: ["id"])).displays
            .first)
        XCTAssertNil(plain.uuid)
        XCTAssertNil(plain.notch)
        XCTAssertNil(plain.menuBarHeight)
        XCTAssertNil(plain.barFrames)
        XCTAssertNil(plain.reservedInsets)
    }
}
