// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class WindowMarkNavigationIntegrationTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let sourceWorkspaceId: WorkspaceDescriptor.ID
        let targetWorkspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
    }

    func testMarkFocusNavigatesAcrossWorkspacesInNiri() throws {
        let fixture = try makeFixture(layoutType: .niri, displayId: 77_101)
        let controller = fixture.controller
        controller.niriLayoutHandler.enableNiriLayout()

        let targetToken = WindowToken(pid: 77_201, windowId: 77_301)
        _ = WindowAdmissionTestSupport.track(
            targetToken,
            in: fixture.targetWorkspaceId,
            controller: controller
        )
        let engine = try XCTUnwrap(controller.niriEngine)
        let node = engine.addWindow(token: targetToken, to: fixture.targetWorkspaceId, afterSelection: nil)
        XCTAssertEqual(controller.windowMarkRegistry.set("niri-target", for: targetToken), .inserted)

        let response = IPCWindowMarkRequestExecutor(controller: controller).response(
            for: .focus(name: "niri-target"),
            id: "niri-mark-focus"
        )

        XCTAssertTrue(response.ok, "unexpected IPC error: \(response.code?.rawValue ?? "none")")
        XCTAssertEqual(
            controller.workspaceManager.activeWorkspace(on: fixture.monitor.id)?.id,
            fixture.targetWorkspaceId
        )
        XCTAssertEqual(
            controller.workspaceManager.niriViewportState(for: fixture.targetWorkspaceId).selectedNodeId,
            node.id
        )
    }

    func testHiddenMarkUsesExplicitAppRevealAndRetainsItsIdentity() throws {
        let fixture = try makeFixture(layoutType: .niri, displayId: 77_103)
        let controller = fixture.controller
        let hiddenToken = WindowToken(pid: 77_401, windowId: 77_501)
        _ = WindowAdmissionTestSupport.track(hiddenToken, in: fixture.sourceWorkspaceId, controller: controller)
        XCTAssertEqual(controller.windowMarkRegistry.set("hidden-target", for: hiddenToken), .inserted)
        _ = controller.workspaceManager.setAppHidden(true, pid: hiddenToken.pid, source: .service)
        let markToken: WindowToken
        switch controller.windowMarkRegistry.lookup("hidden-target") {
        case let .found(token):
            markToken = token
        case .unknown,
             .invalidName:
            XCTFail("live hidden mark was not retained")
            return
        }
        let handle = try XCTUnwrap(controller.workspaceManager.handle(for: markToken))
        let handler = WindowActionHandler(
            controller: controller,
            requestApplicationUnhide: { _ in .requestReportedSent }
        )

        XCTAssertTrue(handler.navigateToExplicitlySelectedWindow(handle: handle))
        XCTAssertTrue(controller.workspaceManager.isAppHidden(pid: hiddenToken.pid))
        XCTAssertEqual(controller.windowMarkRegistry.lookup("hidden-target"), .found(hiddenToken))
        let intent = try XCTUnwrap(controller.intentLedger.openAppRevealFocusIntent(pid: hiddenToken.pid))
        XCTAssertEqual(intent.payload.token, hiddenToken)
        XCTAssertEqual(intent.payload.workspaceId, fixture.sourceWorkspaceId)
    }

    func testMarkFocusActivatesTheExactGroupedDwindleWindow() throws {
        let fixture = try makeFixture(layoutType: .dwindle, displayId: 77_102)
        let controller = fixture.controller
        controller.dwindleLayoutHandler.enableDwindleLayout()

        let markedToken = WindowToken(pid: 77_211, windowId: 77_311)
        let activeToken = WindowToken(pid: 77_212, windowId: 77_312)
        _ = WindowAdmissionTestSupport.track(markedToken, in: fixture.targetWorkspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(activeToken, in: fixture.targetWorkspaceId, controller: controller)
        let engine = try XCTUnwrap(controller.dwindleEngine)
        let screen = fixture.monitor.visibleFrame
        controller.workspaceManager.withEngineMutationScope {
            _ = engine.addWindow(token: markedToken, to: fixture.targetWorkspaceId, activeWindowFrame: nil)
            _ = engine.addWindow(token: activeToken, to: fixture.targetWorkspaceId, activeWindowFrame: nil)
            _ = engine.calculateLayout(for: fixture.targetWorkspaceId, screen: screen)
            XCTAssertTrue(engine.groupWindow(direction: .left, in: fixture.targetWorkspaceId))
            _ = engine.calculateLayout(for: fixture.targetWorkspaceId, screen: screen)
        }
        controller.layoutRefreshController.resetState()
        XCTAssertEqual(engine.activeToken(in: fixture.targetWorkspaceId), activeToken)
        let markedEntry = try XCTUnwrap(controller.workspaceManager.entry(for: markedToken))
        let markedHandle = try XCTUnwrap(controller.workspaceManager.handle(for: markedToken))
        XCTAssertEqual(markedEntry.workspaceId, fixture.targetWorkspaceId)
        XCTAssertEqual(controller.workspaceManager.entry(for: markedHandle)?.workspaceId, fixture.targetWorkspaceId)
        XCTAssertEqual(controller.workspaceManager.activeLayoutKind(for: fixture.targetWorkspaceId), .dwindle)
        XCTAssertFalse(controller.workspaceManager.isAppHidden(pid: markedToken.pid))
        XCTAssertEqual(controller.windowMarkRegistry.set("dwindle-target", for: markedToken), .inserted)

        let response = IPCWindowMarkRequestExecutor(controller: controller).response(
            for: .focus(name: "dwindle-target"),
            id: "dwindle-mark-focus"
        )

        XCTAssertTrue(response.ok, "unexpected IPC error: \(response.code?.rawValue ?? "none")")
        XCTAssertEqual(
            controller.workspaceManager.activeWorkspace(on: fixture.monitor.id)?.id,
            fixture.targetWorkspaceId
        )
        XCTAssertEqual(engine.activeToken(in: fixture.targetWorkspaceId), markedToken)
    }

    private func makeFixture(layoutType: LayoutType, displayId: UInt32) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMWindowMarkNavigation")
        let monitor = Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            hasNotch: false,
            name: "Window Mark Navigation"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        _ = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(
                named: "771",
                layoutType: layoutType,
                controller: controller
            )
        )
        let sourceWorkspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "771", createIfMissing: false)
        )
        let targetWorkspaceId = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(
                named: "772",
                layoutType: layoutType,
                controller: controller
            )
        )
        _ = controller.workspaceManager.focusWorkspace(named: "771")
        return Fixture(
            controller: controller,
            sourceWorkspaceId: sourceWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            monitor: monitor
        )
    }
}
