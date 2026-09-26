// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class DwindleIncomingWindowStackingIntegrationTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let engine: DwindleLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let otherWorkspaceId: WorkspaceDescriptor.ID
    }

    func testMarkedIncomingWindowJoinsSelectedTile() throws {
        let fixture = try makeFixture(seed: 891_000, stackIncomingWindows: true)
        let existing = addExistingWindow(seed: 891_100, in: fixture.workspaceId, fixture: fixture)
        let incoming = WindowToken(pid: 891_200, windowId: 891_201)
        fixture.controller.dwindleLayoutHandler.markIncomingWindowForStacking(incoming, in: fixture.workspaceId)
        _ = WindowAdmissionTestSupport.track(incoming, in: fixture.workspaceId, controller: fixture.controller)

        layout(fixture.workspaceId, fixture: fixture)

        XCTAssertEqual(fixture.engine.tileCount(in: fixture.workspaceId), 1)
        let snapshot = try XCTUnwrap(fixture.engine.tileSnapshot(for: incoming, in: fixture.workspaceId))
        XCTAssertEqual(snapshot.members.map(\.token), [existing, incoming])
        XCTAssertEqual(snapshot.activeToken, incoming)
        XCTAssertFalse(fixture.controller.dwindleLayoutHandler.stackableIncomingTokens.contains(incoming))
    }

    func testUnmarkedWindowStillSplits() throws {
        let fixture = try makeFixture(seed: 892_000, stackIncomingWindows: true)
        addExistingWindow(seed: 892_100, in: fixture.workspaceId, fixture: fixture)
        let retiled = WindowToken(pid: 892_200, windowId: 892_201)
        _ = WindowAdmissionTestSupport.track(retiled, in: fixture.workspaceId, controller: fixture.controller)

        layout(fixture.workspaceId, fixture: fixture)

        XCTAssertEqual(fixture.engine.tileCount(in: fixture.workspaceId), 2)
    }

    func testMarkedWindowSplitsWhenSettingIsOff() throws {
        let fixture = try makeFixture(seed: 893_000, stackIncomingWindows: false)
        addExistingWindow(seed: 893_100, in: fixture.workspaceId, fixture: fixture)
        let incoming = WindowToken(pid: 893_200, windowId: 893_201)
        fixture.controller.dwindleLayoutHandler.markIncomingWindowForStacking(incoming, in: fixture.workspaceId)
        _ = WindowAdmissionTestSupport.track(incoming, in: fixture.workspaceId, controller: fixture.controller)

        layout(fixture.workspaceId, fixture: fixture)

        XCTAssertEqual(fixture.engine.tileCount(in: fixture.workspaceId), 2)
        XCTAssertFalse(fixture.controller.dwindleLayoutHandler.stackableIncomingTokens.contains(incoming))
    }

    func testWindowsAreNotMarkedBeforeInitialRefreshCompletes() throws {
        let fixture = try makeFixture(seed: 894_000, stackIncomingWindows: true)
        fixture.controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = false
        let token = WindowToken(pid: 894_200, windowId: 894_201)

        fixture.controller.dwindleLayoutHandler.markIncomingWindowForStacking(token, in: fixture.workspaceId)

        XCTAssertFalse(fixture.controller.dwindleLayoutHandler.stackableIncomingTokens.contains(token))
    }

    func testWindowsAdmittedToNiriWorkspaceAreNotMarked() throws {
        let fixture = try makeFixture(seed: 897_000, stackIncomingWindows: true)
        let niriWorkspaceId = try XCTUnwrap(
            fixture.controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        XCTAssertEqual(fixture.controller.workspaceManager.activeLayoutKind(for: niriWorkspaceId), .niri)
        let token = WindowToken(pid: 897_200, windowId: 897_201)

        fixture.controller.dwindleLayoutHandler.markIncomingWindowForStacking(token, in: niriWorkspaceId)

        XCTAssertFalse(fixture.controller.dwindleLayoutHandler.stackableIncomingTokens.contains(token))
    }

    func testMoveToDwindleWorkspaceStacksIntoTargetSelectedTile() throws {
        let fixture = try makeFixture(seed: 895_000, stackIncomingWindows: true)
        let moving = addExistingWindow(seed: 895_100, in: fixture.workspaceId, fixture: fixture)
        let target = addExistingWindow(seed: 895_200, in: fixture.otherWorkspaceId, fixture: fixture)

        let outcome = fixture.controller.workspaceNavigationHandler.moveWindow(
            handle: WindowHandle(id: moving),
            toWorkspaceId: fixture.otherWorkspaceId
        )
        layout(fixture.otherWorkspaceId, fixture: fixture)

        XCTAssertTrue(outcome.didMutate)
        XCTAssertEqual(fixture.engine.tileCount(in: fixture.otherWorkspaceId), 1)
        XCTAssertEqual(
            try XCTUnwrap(fixture.engine.tileSnapshot(for: moving, in: fixture.otherWorkspaceId)).members.map(\.token),
            [target, moving]
        )
    }

    func testMoveToDwindleWorkspaceSplitsWhenSettingIsOff() throws {
        let fixture = try makeFixture(seed: 896_000, stackIncomingWindows: false)
        let moving = addExistingWindow(seed: 896_100, in: fixture.workspaceId, fixture: fixture)
        addExistingWindow(seed: 896_200, in: fixture.otherWorkspaceId, fixture: fixture)

        let outcome = fixture.controller.workspaceNavigationHandler.moveWindow(
            handle: WindowHandle(id: moving),
            toWorkspaceId: fixture.otherWorkspaceId
        )
        layout(fixture.otherWorkspaceId, fixture: fixture)

        XCTAssertTrue(outcome.didMutate)
        XCTAssertEqual(fixture.engine.tileCount(in: fixture.otherWorkspaceId), 2)
    }

    private func makeFixture(seed: Int, stackIncomingWindows: Bool) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(
            prefix: "OmniWMDwindleIncomingWindowStackingIntegrationTests-\(seed)"
        )
        controller.motionPolicy.animationsEnabled = false
        let frame = CGRect(x: 0, y: 0, width: 1_600, height: 900)
        let monitor = Monitor(
            id: .init(displayId: CGDirectDisplayID(seed)),
            displayId: CGDirectDisplayID(seed),
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Landscape"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.settings.workspaces.configurations.append(contentsOf: [
            WorkspaceConfiguration(name: "91", layoutType: .dwindle),
            WorkspaceConfiguration(name: "92", layoutType: .dwindle)
        ])
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "91"))
        let otherWorkspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "92"))
        controller.workspaceManager.assignWorkspaceToMonitor(workspaceId, monitorId: monitor.id)
        controller.workspaceManager.assignWorkspaceToMonitor(otherWorkspaceId, monitorId: monitor.id)
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspaceId, on: monitor.id))
        _ = controller.workspaceManager.focusWorkspace(id: workspaceId)
        controller.dwindleLayoutHandler.enableDwindleLayout()
        controller.layoutRefreshController.resetState()
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        controller.settings.dwindle.stackIncomingWindows = stackIncomingWindows
        let engine = try XCTUnwrap(controller.dwindleEngine)
        return Fixture(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            otherWorkspaceId: otherWorkspaceId
        )
    }

    @discardableResult
    private func addExistingWindow(
        seed: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        fixture: Fixture
    ) -> WindowToken {
        let token = WindowToken(pid: pid_t(seed), windowId: seed + 1)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: fixture.controller)
        layout(workspaceId, fixture: fixture)
        return token
    }

    private func layout(_ workspaceId: WorkspaceDescriptor.ID, fixture: Fixture) {
        _ = fixture.controller.workspaceManager.withEngineMutationScope(
            in: workspaceId,
            label: "dwindle_stacking_fixture_layout"
        ) {
            fixture.controller.dwindleLayoutHandler.layoutWithDwindleEngine(activeWorkspaces: [workspaceId])
        }
    }
}
