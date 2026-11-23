// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NativeFullscreenWorkspaceSwitchTests: XCTestCase {
    func testSwitchSelectsPlaceholderWithoutFrontingByDefault() async throws {
        let fixture = try makeFixture(prefix: "OmniWMNativeFullscreenSwitchDefaultTests")

        XCTAssertTrue(fixture.controller.workspaceNavigationHandler.switchWorkspace(rawWorkspaceID: "1"))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertFalse(fixture.recorder.operations.contains("raise"))
    }

    func testSwitchFrontsNativeFullscreenWindowWhenEnabled() async throws {
        let fixture = try makeFixture(prefix: "OmniWMNativeFullscreenSwitchEnabledTests")
        fixture.controller.settings.workspaces.focusNativeFullscreenOnSwitch = true

        XCTAssertTrue(fixture.controller.workspaceNavigationHandler.switchWorkspace(rawWorkspaceID: "1"))
        await WindowAdmissionTestSupport.drainLayoutRefreshes(fixture.controller)

        XCTAssertEqual(
            fixture.recorder.operations,
            ["focus:\(fixture.fullscreenToken.pid):\(fixture.fullscreenToken.windowId)", "raise"]
        )
    }

    private func makeFixture(prefix: String) throws -> Fixture {
        let recorder = FocusRecorder()
        let controller = WindowAdmissionTestSupport.controller(
            prefix: prefix,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { recorder.operations.append("activate:\($0)") },
                focusSpecificWindow: { pid, windowId, _ in
                    recorder.operations.append("focus:\(pid):\(windowId)")
                },
                raiseWindow: { _ in recorder.operations.append("raise") },
                orderWindow: { recorder.operations.append("order:\($0)") }
            )
        )
        let monitor = Monitor(
            id: .init(displayId: 56_901),
            displayId: 56_901,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            hasNotch: false,
            name: "Native Fullscreen Switch"
        )
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        let fullscreenWorkspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        _ = try XCTUnwrap(manager.workspaceId(for: "2", createIfMissing: true))
        _ = manager.focusWorkspace(named: "1")
        let fullscreenToken = WindowToken(pid: 569_001, windowId: 569_101)
        _ = manager.addWindow(
            WindowAdmissionTestSupport.axRef(for: fullscreenToken),
            pid: fullscreenToken.pid,
            windowId: fullscreenToken.windowId,
            to: fullscreenWorkspaceId
        )
        XCTAssertTrue(
            manager.confirmManagedFocus(
                fullscreenToken,
                in: fullscreenWorkspaceId,
                onMonitor: monitor.id,
                activateWorkspaceOnMonitor: false
            )
        )
        XCTAssertTrue(manager.markNativeFullscreenSuspended(fullscreenToken))
        XCTAssertNotNil(manager.focusWorkspace(named: "2"))
        recorder.operations.removeAll()

        return Fixture(controller: controller, fullscreenToken: fullscreenToken, recorder: recorder)
    }

    private final class FocusRecorder: @unchecked Sendable {
        var operations: [String] = []
    }

    private struct Fixture {
        let controller: WMController
        let fullscreenToken: WindowToken
        let recorder: FocusRecorder
    }
}
