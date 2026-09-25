// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceSkipEmptyNavigationTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let monitor: Monitor
        let workspaces: [WorkspaceDescriptor.ID]
    }

    func testRelativeSwitchVisitsEmptyWorkspaceWhenEmptyWorkspacesAreShown() throws {
        let fixture = try makeFixture(occupied: [0])
        defer { fixture.controller.deadlineWheel.stop() }

        XCTAssertEqual(cycle(fixture, isNext: true, steps: 1), [1])
    }

    func testRelativeSwitchSkipsEmptyWorkspacesAndWrapsWhenBarHidesThem() throws {
        let fixture = try makeFixture(occupied: [0, 1, 2])
        defer { fixture.controller.deadlineWheel.stop() }
        fixture.controller.settings.workspaceBar.hideEmptyWorkspaces = true

        XCTAssertEqual(cycle(fixture, isNext: true, steps: 3), [1, 2, 0])
        XCTAssertEqual(cycle(fixture, isNext: false, steps: 3), [2, 1, 0])
    }

    func testRelativeSwitchLeavesEmptyActiveWorkspaceForOccupiedNeighbor() throws {
        let fixture = try makeFixture(occupied: [0, 2])
        defer { fixture.controller.deadlineWheel.stop() }
        fixture.controller.settings.workspaceBar.hideEmptyWorkspaces = true
        let manager = fixture.controller.workspaceManager
        XCTAssertTrue(manager.setActiveWorkspace(fixture.workspaces[3], on: fixture.monitor.id))

        XCTAssertEqual(cycle(fixture, isNext: true, steps: 3), [0, 2, 0])
    }

    func testSkipEmptyReturnsNilWhenOnlyCurrentWorkspaceIsOccupied() throws {
        let fixture = try makeFixture(occupied: [0])
        defer { fixture.controller.deadlineWheel.stop() }
        let manager = fixture.controller.workspaceManager

        XCTAssertNil(manager.nextWorkspaceInOrder(
            on: fixture.monitor.id,
            from: fixture.workspaces[0],
            wrapAround: true,
            skipEmpty: true
        ))
        XCTAssertEqual(
            manager.nextWorkspaceInOrder(on: fixture.monitor.id, from: fixture.workspaces[0], wrapAround: true)?.id,
            fixture.workspaces[1]
        )
    }

    private func cycle(_ fixture: Fixture, isNext: Bool, steps: Int) -> [Int?] {
        let manager = fixture.controller.workspaceManager
        return (0 ..< steps).map { _ in
            fixture.controller.workspaceNavigationHandler.switchWorkspaceRelative(isNext: isNext)
            let active = manager.activeWorkspaceOrFirst(on: fixture.monitor.id)?.id
            return active.flatMap { fixture.workspaces.firstIndex(of: $0) }
        }
    }

    private func makeFixture(occupied: Set<Int>) throws -> Fixture {
        let controller = WMController(
            settings: makeSettings(),
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
        controller.layoutRefreshController.displayLinkActivationForTests = { _ in true }
        let monitor = Monitor(
            id: .init(displayId: 1),
            displayId: 1,
            frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900),
            hasNotch: false,
            name: "Test"
        )
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        let workspaces = try (1 ... 5).map {
            try XCTUnwrap(manager.workspaceId(for: String($0), createIfMissing: true))
        }
        for index in occupied.sorted() {
            let pid = pid_t(8_001 + index)
            let windowId = 8_101 + index
            _ = manager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid,
                windowId: windowId,
                to: workspaces[index]
            )
        }
        XCTAssertTrue(manager.setActiveWorkspace(workspaces[0], on: monitor.id))
        return Fixture(controller: controller, monitor: monitor, workspaces: workspaces)
    }

    private func makeSettings() -> SettingsStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSkipEmptyNavigationTests-\(UUID().uuidString)", isDirectory: true)
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
