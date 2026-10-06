// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class FloatingFocusToggleTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let manager: WorkspaceManager
        let workspace1: WorkspaceDescriptor.ID
        let workspace2: WorkspaceDescriptor.ID
    }

    func testOnlyAFloatingWindowOnTheWorkspaceIsAToggleSource() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let tiled = addWindow(5001, 11, to: fixture.workspace1, manager: fixture.manager)
        let floating = addWindow(5001, 12, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        let otherFloating = addWindow(5001, 13, to: fixture.workspace2, mode: .floating, manager: fixture.manager)

        XCTAssertTrue(fixture.manager.isFloatingFocusToggleSource(floating, in: fixture.workspace1))
        XCTAssertFalse(fixture.manager.isFloatingFocusToggleSource(tiled, in: fixture.workspace1))
        XCTAssertFalse(fixture.manager.isFloatingFocusToggleSource(otherFloating, in: fixture.workspace1))
        XCTAssertFalse(fixture.manager.isFloatingFocusToggleSource(nil, in: fixture.workspace1))
    }

    func testFloatingTargetPrefersTheFloatingWindowFocusedLast() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let tiled = addWindow(5002, 21, to: fixture.workspace1, manager: fixture.manager)
        let remembered = addWindow(5002, 22, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        _ = addWindow(5002, 23, to: fixture.workspace1, mode: .floating, manager: fixture.manager)

        _ = fixture.manager.rememberFocus(remembered, in: fixture.workspace1)
        _ = fixture.manager.rememberFocus(tiled, in: fixture.workspace1)

        XCTAssertEqual(fixture.manager.floatingFocusToggleTarget(in: fixture.workspace1), remembered)
    }

    func testFloatingTargetFallsBackToTheTopmostRaisedWindow() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        _ = addWindow(5003, 31, to: fixture.workspace1, manager: fixture.manager)
        _ = addWindow(5003, 33, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        let topmost = addWindow(5004, 32, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        _ = addWindow(5005, 34, to: fixture.workspace2, mode: .floating, manager: fixture.manager)

        XCTAssertEqual(fixture.manager.floatingFocusToggleTarget(in: fixture.workspace1), topmost)
    }

    func testFloatingTargetIsAbsentWithoutFloatingWindowsOnTheWorkspace() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        _ = addWindow(5006, 41, to: fixture.workspace1, manager: fixture.manager)
        _ = addWindow(5006, 42, to: fixture.workspace2, mode: .floating, manager: fixture.manager)

        XCTAssertNil(fixture.manager.floatingFocusToggleTarget(in: fixture.workspace1))
    }

    func testToggleFromTiledFocusFocusesTheRememberedFloatingWindow() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let tiled = addWindow(5007, 51, to: fixture.workspace1, manager: fixture.manager)
        let remembered = addWindow(5007, 52, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        _ = addWindow(5007, 53, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        _ = fixture.manager.rememberFocus(remembered, in: fixture.workspace1)
        XCTAssertTrue(fixture.manager.setManagedFocus(tiled, in: fixture.workspace1))

        XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .executed)
        XCTAssertEqual(fixture.manager.pendingFocusedToken, remembered)
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, remembered)
    }

    func testToggleFromFloatingFocusReturnsToTheTiledWindowFocusedLast() async throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let firstTiled = addWindow(5008, 61, to: fixture.workspace1, manager: fixture.manager)
        let secondTiled = addWindow(5008, 62, to: fixture.workspace1, manager: fixture.manager)
        let floating = addWindow(5008, 63, to: fixture.workspace1, mode: .floating, manager: fixture.manager)
        _ = fixture.manager.rememberFocus(secondTiled, in: fixture.workspace1)
        _ = fixture.manager.rememberFocus(firstTiled, in: fixture.workspace1)
        XCTAssertTrue(fixture.manager.setManagedFocus(floating, in: fixture.workspace1))

        XCTAssertEqual(fixture.manager.preferredFocusToken(in: fixture.workspace1), firstTiled)
        XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .executed)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while fixture.controller.intentLedger.activeManagedRequest?.token != firstTiled, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.controller.intentLedger.activeManagedRequest?.token, firstTiled)
    }

    func testToggleWithoutACounterpartReportsNoChange() throws {
        let fixture = try makeFixture()
        defer { fixture.controller.layoutRefreshController.resetState() }
        let tiled = addWindow(5009, 71, to: fixture.workspace1, manager: fixture.manager)
        XCTAssertTrue(fixture.manager.setManagedFocus(tiled, in: fixture.workspace1))

        XCTAssertEqual(fixture.controller.toggleFloatingFocus(), .noChange)
        XCTAssertNil(fixture.controller.intentLedger.activeManagedRequest)

        let floatingFixture = try makeFixture()
        defer { floatingFixture.controller.layoutRefreshController.resetState() }
        let floating = addWindow(
            5010,
            81,
            to: floatingFixture.workspace1,
            mode: .floating,
            manager: floatingFixture.manager
        )
        XCTAssertTrue(floatingFixture.manager.setManagedFocus(floating, in: floatingFixture.workspace1))

        XCTAssertEqual(floatingFixture.controller.toggleFloatingFocus(), .noChange)
    }

    private func addWindow(
        _ pid: pid_t,
        _ windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode = .tiling,
        manager: WorkspaceManager
    ) -> WindowToken {
        manager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId,
            mode: mode
        )
    }

    private func makeFixture() throws -> Fixture {
        let monitor = Monitor(
            id: .init(displayId: 472_000),
            displayId: 472_000,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "FloatingFocusToggle"
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloatingFocusToggleTests-\(UUID().uuidString)", isDirectory: true)
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
        settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .niri
            )
        ]
        let controller = WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        controller.niriLayoutHandler.enableNiriLayout()
        let workspace1 = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        let workspace2 = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "2"))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspace1, on: monitor.id))
        controller.layoutRefreshController.resetState()

        return Fixture(
            controller: controller,
            manager: controller.workspaceManager,
            workspace1: workspace1,
            workspace2: workspace2
        )
    }
}
