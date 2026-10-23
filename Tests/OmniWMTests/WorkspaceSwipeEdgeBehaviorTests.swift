// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class WorkspaceSwipeEdgeBehaviorTests: XCTestCase {
    func testCycleWrapsAtBothEnds() throws {
        let fixture = try makeFixture(.cycle, occupied: ["1", "2", "3"])

        XCTAssertEqual(fixture.target(next: true, from: "3"), fixture.ids["1"])
        XCTAssertEqual(fixture.target(next: false, from: "1"), fixture.ids["3"])
    }

    func testNoneRefusesPastEitherEnd() throws {
        let fixture = try makeFixture(.none, occupied: ["1", "2", "3"])

        XCTAssertNil(fixture.target(next: true, from: "3"))
        XCTAssertNil(fixture.target(next: false, from: "1"))
        XCTAssertEqual(fixture.target(next: true, from: "2"), fixture.ids["3"])
    }

    func testOnePastCreatesAWorkspaceOnlyWhenAsked() throws {
        let fixture = try makeFixture(.onePast, occupied: ["1", "2", "3"])
        let manager = fixture.controller.workspaceManager

        XCTAssertNil(fixture.target(next: true, from: "3"))
        XCTAssertNil(manager.workspaceId(named: "4"))

        let created = try XCTUnwrap(fixture.target(next: true, from: "3", create: true))

        XCTAssertEqual(created, manager.workspaceId(named: "4"))
        XCTAssertEqual(manager.monitor(for: created)?.id, fixture.monitorId)
        XCTAssertFalse(manager.isOccupied(created))
        XCTAssertNil(fixture.navigation.swipeTargetWorkspace(
            isNext: true, from: created, on: fixture.monitorId, createIfNeeded: true
        ))
        XCTAssertNil(fixture.target(next: false, from: "1", create: true))
    }

    func testOnePastReusesAnExistingEmptyWorkspaceWhenEmptiesAreHidden() throws {
        let fixture = try makeFixture(.onePast, occupied: ["1", "2"], hideEmpty: true)

        XCTAssertEqual(fixture.target(next: true, from: "2"), fixture.ids["3"])
        XCTAssertNil(fixture.target(next: true, from: "3", create: true))
        XCTAssertNil(fixture.controller.workspaceManager.workspaceId(named: "4"))
    }

    func testOnePastSwipeFallbackSwitchesToTheCreatedWorkspace() throws {
        let fixture = try makeFixture(.onePast, occupied: ["1", "2", "3"])
        let manager = fixture.controller.workspaceManager
        XCTAssertTrue(manager.setActiveWorkspace(try XCTUnwrap(fixture.ids["3"]), on: fixture.monitorId))

        fixture.navigation.switchWorkspaceBySwipe(isNext: true, monitorId: fixture.monitorId)

        XCTAssertEqual(manager.activeWorkspace(on: fixture.monitorId)?.name, "4")
    }

    func testHotkeyNavigationStillWrapsWhenSwipesStop() throws {
        let fixture = try makeFixture(.none, occupied: ["1", "2", "3"])
        let manager = fixture.controller.workspaceManager
        XCTAssertTrue(manager.setActiveWorkspace(try XCTUnwrap(fixture.ids["3"]), on: fixture.monitorId))

        fixture.navigation.switchWorkspaceBySwipe(isNext: true, monitorId: fixture.monitorId)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.monitorId)?.name, "3")

        fixture.navigation.switchWorkspaceRelative(isNext: true, monitorId: fixture.monitorId)
        XCTAssertEqual(manager.activeWorkspace(on: fixture.monitorId)?.name, "1")
    }

    @MainActor
    private struct Fixture {
        let controller: WMController
        let monitorId: Monitor.ID
        let ids: [String: WorkspaceDescriptor.ID]

        var navigation: WorkspaceNavigationHandler {
            controller.workspaceNavigationHandler
        }

        func target(next: Bool, from name: String, create: Bool = false) -> WorkspaceDescriptor.ID? {
            guard let id = ids[name] else { return nil }
            return navigation.swipeTargetWorkspace(isNext: next, from: id, on: monitorId, createIfNeeded: create)?.id
        }
    }

    private func makeFixture(
        _ behavior: WorkspaceSwipeEdgeBehavior,
        occupied: Set<String>,
        hideEmpty: Bool = false
    ) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller()
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let monitor = Monitor(
            id: .init(displayId: 1), displayId: 1, frame: frame, visibleFrame: frame, hasNotch: false, name: "Edge"
        )
        controller.settings.workspaces.configurations = ["1", "2", "3"].map { WorkspaceConfiguration(name: $0) }
        controller.settings.workspaceBar.hideEmptyWorkspaces = hideEmpty
        controller.settings.gestures.workspaceSwipeEdgeBehavior = behavior
        let manager = controller.workspaceManager
        manager.applyMonitorConfigurationChange([monitor])
        manager.applySettings()
        var ids: [String: WorkspaceDescriptor.ID] = [:]
        for (index, name) in ["1", "2", "3"].enumerated() {
            let id = try XCTUnwrap(manager.workspaceId(for: name, createIfMissing: true))
            ids[name] = id
            if occupied.contains(name) {
                _ = WindowAdmissionTestSupport.track(
                    WindowToken(pid: 981_001, windowId: 981_100 + index), in: id, controller: controller
                )
            }
        }
        XCTAssertTrue(manager.setActiveWorkspace(try XCTUnwrap(ids["1"]), on: monitor.id))
        return Fixture(controller: controller, monitorId: monitor.id, ids: ids)
    }
}
