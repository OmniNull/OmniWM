// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class WindowMarkSummonIntegrationTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let sourceWorkspaceId: WorkspaceDescriptor.ID
        let targetWorkspaceId: WorkspaceDescriptor.ID
        let sourceWorkspaceName: String
        let targetWorkspaceName: String
        let monitor: Monitor
        let markedToken: WindowToken
        let anchorToken: WindowToken
    }

    func testSummonMarkedWindowRightInNiriPreservesSizingAndSelection() throws {
        let fixture = try makeFixture(layoutType: .niri, displayId: 78_301)
        let controller = fixture.controller
        let manager = controller.workspaceManager
        let engine = try XCTUnwrap(controller.niriEngine)

        _ = manager.focusWorkspace(named: fixture.sourceWorkspaceName)
        _ = manager.setManagedFocus(fixture.markedToken, in: fixture.sourceWorkspaceId, onMonitor: fixture.monitor.id)
        _ = manager.confirmManagedFocus(
            fixture.markedToken,
            in: fixture.sourceWorkspaceId,
            onMonitor: fixture.monitor.id,
            activateWorkspaceOnMonitor: true
        )
        XCTAssertEqual(
            controller.commandHandler.performCommand(.sizing(.setContainerPrimarySpan(.setProportion(50)))),
            .executed
        )
        let sourceNode = try XCTUnwrap(engine.findNode(for: fixture.markedToken, in: fixture.sourceWorkspaceId))
        let sourceColumn = try XCTUnwrap(engine.findColumn(containing: sourceNode, in: fixture.sourceWorkspaceId))
        XCTAssertEqual(sourceColumn.width, .proportion(0.5))
        XCTAssertTrue(sourceColumn.hasManualSingleWindowWidthOverride)

        focusAnchor(fixture)
        XCTAssertEqual(controller.windowMarkRegistry.set("niri-mark", for: fixture.markedToken), .inserted)
        let response = summonResponse(fixture, mark: "niri-mark")

        XCTAssertTrue(response.ok, "unexpected IPC error: \(response.code?.rawValue ?? "none")")
        XCTAssertEqual(response.kind, .windowMark)
        XCTAssertEqual(response.status, .executed)
        XCTAssertEqual(controller.workspaceManager.workspace(for: fixture.markedToken), fixture.targetWorkspaceId)
        XCTAssertEqual(controller.windowMarkRegistry.lookup("niri-mark"), .found(fixture.markedToken))

        let movedNode = try XCTUnwrap(engine.findNode(for: fixture.markedToken, in: fixture.targetWorkspaceId))
        let movedColumn = try XCTUnwrap(engine.findColumn(containing: movedNode, in: fixture.targetWorkspaceId))
        let anchorColumn = try XCTUnwrap(engine.findColumn(
            containing: try XCTUnwrap(engine.findNode(for: fixture.anchorToken, in: fixture.targetWorkspaceId)),
            in: fixture.targetWorkspaceId
        ))
        let columns = engine.columns(in: fixture.targetWorkspaceId)
        XCTAssertEqual(columns.firstIndex(where: { $0.id == movedColumn.id }), 1)
        XCTAssertNotEqual(movedColumn.id, anchorColumn.id)
        XCTAssertEqual(movedColumn.width, .proportion(0.5))
        XCTAssertTrue(movedColumn.hasManualSingleWindowWidthOverride)
        XCTAssertEqual(
            manager.niriViewportState(for: fixture.targetWorkspaceId).selectedNodeId,
            movedNode.id
        )
    }

    func testSummonMarkedWindowRightInDwindleMovesAndSelectsTheMarkedWindow() async throws {
        let fixture = try makeFixture(layoutType: .dwindle, displayId: 78_302)
        let controller = fixture.controller
        let engine = try XCTUnwrap(controller.dwindleEngine)
        XCTAssertEqual(controller.windowMarkRegistry.set("dwindle-mark", for: fixture.markedToken), .inserted)

        let response = summonResponse(fixture, mark: "dwindle-mark")
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertTrue(response.ok, "unexpected IPC error: \(response.code?.rawValue ?? "none")")
        XCTAssertEqual(response.status, .executed)
        XCTAssertEqual(controller.workspaceManager.workspace(for: fixture.markedToken), fixture.targetWorkspaceId)
        XCTAssertNotNil(engine.findNode(for: fixture.markedToken, in: fixture.targetWorkspaceId))
        XCTAssertEqual(engine.tileCount(in: fixture.sourceWorkspaceId), 0)
        XCTAssertEqual(engine.tileCount(in: fixture.targetWorkspaceId), 2)
        let currentEngine = try XCTUnwrap(controller.dwindleEngine)
        XCTAssertTrue(currentEngine === engine)
        XCTAssertEqual(currentEngine.activeToken(in: fixture.targetWorkspaceId), fixture.markedToken)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, fixture.markedToken)
        XCTAssertEqual(controller.windowMarkRegistry.lookup("dwindle-mark"), .found(fixture.markedToken))
    }

    func testOrdinarySummonRightInDwindleKeepsMoveAndSelectionSemantics() async throws {
        let fixture = try makeFixture(layoutType: .dwindle, displayId: 78_306)
        let controller = fixture.controller
        let engine = try XCTUnwrap(controller.dwindleEngine)
        XCTAssertEqual(engine.tileCount(in: fixture.targetWorkspaceId), 1)

        let summoned = controller.windowActionHandler.summonWindowRight(
            handle: WindowHandle(id: fixture.markedToken),
            anchorToken: fixture.anchorToken,
            anchorWorkspaceId: fixture.targetWorkspaceId
        )
        XCTAssertTrue(summoned)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertEqual(controller.workspaceManager.workspace(for: fixture.markedToken), fixture.targetWorkspaceId)
        XCTAssertEqual(engine.tileCount(in: fixture.sourceWorkspaceId), 0)
        XCTAssertEqual(engine.tileCount(in: fixture.targetWorkspaceId), 2)
        XCTAssertNotNil(engine.findNode(for: fixture.markedToken, in: fixture.targetWorkspaceId))
        XCTAssertEqual(engine.activeToken(in: fixture.targetWorkspaceId), fixture.markedToken)
        XCTAssertEqual(controller.intentLedger.activeManagedRequest?.token, fixture.markedToken)
    }

    func testSummonRefusalsAreTypedAndDoNotMoveTheMarkedWindow() throws {
        let noAnchorFixture = try makeFixture(layoutType: .niri, displayId: 78_303, shouldFocusAnchor: false)
        let noAnchorController = noAnchorFixture.controller
        XCTAssertEqual(noAnchorController.windowMarkRegistry.set("known", for: noAnchorFixture.markedToken), .inserted)
        let noAnchor = summonResponse(noAnchorFixture, mark: "known")
        XCTAssertEqual(noAnchor.code, .noFocusedWindow)
        XCTAssertEqual(
            noAnchorController.workspaceManager.workspace(for: noAnchorFixture.markedToken),
            noAnchorFixture.sourceWorkspaceId
        )

        let staleToken = WindowToken(pid: 78_399, windowId: 78_499)
        XCTAssertEqual(noAnchorController.windowMarkRegistry.set("stale", for: staleToken), .inserted)
        XCTAssertEqual(summonResponse(noAnchorFixture, mark: "stale").code, .staleMark)
        XCTAssertEqual(noAnchorController.windowMarkRegistry.lookup("stale"), .unknown)
        XCTAssertEqual(summonResponse(noAnchorFixture, mark: "missing").code, .unknownMark)

        let focusedFixture = try makeFixture(layoutType: .niri, displayId: 78_304)
        let controller = focusedFixture.controller
        XCTAssertEqual(controller.windowMarkRegistry.set("hidden", for: focusedFixture.markedToken), .inserted)
        controller.workspaceManager.setAppHidden(true, pid: focusedFixture.markedToken.pid, source: .service)
        XCTAssertEqual(summonResponse(focusedFixture, mark: "hidden").code, .hiddenWindow)
        XCTAssertEqual(
            controller.workspaceManager.workspace(for: focusedFixture.markedToken),
            focusedFixture.sourceWorkspaceId
        )
        XCTAssertEqual(controller.windowMarkRegistry.lookup("hidden"), .found(focusedFixture.markedToken))

        XCTAssertEqual(controller.windowMarkRegistry.set("anchor", for: focusedFixture.anchorToken), .inserted)
        XCTAssertEqual(summonResponse(focusedFixture, mark: "anchor").code, .selfSummon)
        XCTAssertEqual(
            controller.workspaceManager.workspace(for: focusedFixture.anchorToken),
            focusedFixture.targetWorkspaceId
        )

        controller.isEnabled = false
        XCTAssertEqual(summonResponse(focusedFixture, mark: "hidden").code, .disabled)
        controller.isEnabled = true
        controller.settings.animationsEnabled = false
        controller.toggleOverview()
        defer {
            if controller.isOverviewOpen() {
                controller.toggleOverview()
            }
        }
        XCTAssertEqual(summonResponse(focusedFixture, mark: "anchor").code, .overviewOpen)
        XCTAssertEqual(
            controller.workspaceManager.workspace(for: focusedFixture.anchorToken),
            focusedFixture.targetWorkspaceId
        )
    }

    func testSummonRefusesWhenTheTargetLayoutEngineIsUnavailable() throws {
        let fixture = try makeFixture(layoutType: .niri, displayId: 78_305)
        let controller = fixture.controller
        XCTAssertEqual(controller.windowMarkRegistry.set("unsupported", for: fixture.markedToken), .inserted)
        controller.niriEngine = nil

        let response = summonResponse(fixture, mark: "unsupported")

        XCTAssertEqual(response.code, .unsupportedLayout)
        XCTAssertEqual(controller.workspaceManager.workspace(for: fixture.markedToken), fixture.sourceWorkspaceId)
        XCTAssertEqual(controller.windowMarkRegistry.lookup("unsupported"), .found(fixture.markedToken))
    }

    private func makeFixture(
        layoutType: LayoutType,
        displayId: UInt32,
        shouldFocusAnchor: Bool = true
    ) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMWindowMarkSummon")
        let monitor = Monitor(
            id: .init(displayId: displayId),
            displayId: displayId,
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            hasNotch: false,
            name: "Window Mark Summon"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let sourceWorkspaceName = String(displayId % 1_000)
        let targetWorkspaceName = String(displayId % 1_000 + 1)
        let sourceWorkspaceId = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(
                named: sourceWorkspaceName,
                layoutType: layoutType,
                controller: controller
            )
        )
        let targetWorkspaceId = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(
                named: targetWorkspaceName,
                layoutType: layoutType,
                controller: controller
            )
        )

        if layoutType == .dwindle {
            controller.dwindleLayoutHandler.enableDwindleLayout()
        } else {
            controller.niriLayoutHandler.enableNiriLayout()
        }

        let markedToken = WindowToken(pid: pid_t(displayId) + 1, windowId: Int(displayId) + 101)
        let anchorToken = WindowToken(pid: pid_t(displayId) + 2, windowId: Int(displayId) + 102)
        _ = WindowAdmissionTestSupport.track(markedToken, in: sourceWorkspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(anchorToken, in: targetWorkspaceId, controller: controller)

        switch layoutType {
        case .dwindle:
            let engine = try XCTUnwrap(controller.dwindleEngine)
            controller.workspaceManager.withEngineMutationScope {
                _ = engine.addWindow(token: markedToken, to: sourceWorkspaceId, activeWindowFrame: nil)
                _ = engine.addWindow(token: anchorToken, to: targetWorkspaceId, activeWindowFrame: nil)
            }
        case .defaultLayout,
             .niri:
            let engine = try XCTUnwrap(controller.niriEngine)
            controller.workspaceManager.withEngineMutationScope {
                _ = engine.addWindow(token: markedToken, to: sourceWorkspaceId, afterSelection: nil)
                _ = engine.addWindow(token: anchorToken, to: targetWorkspaceId, afterSelection: nil)
            }
        }

        let fixture = Fixture(
            controller: controller,
            sourceWorkspaceId: sourceWorkspaceId,
            targetWorkspaceId: targetWorkspaceId,
            sourceWorkspaceName: sourceWorkspaceName,
            targetWorkspaceName: targetWorkspaceName,
            monitor: monitor,
            markedToken: markedToken,
            anchorToken: anchorToken
        )
        if shouldFocusAnchor {
            focusAnchor(fixture)
        }
        return fixture
    }

    private func focusAnchor(_ fixture: Fixture) {
        let manager = fixture.controller.workspaceManager
        _ = manager.focusWorkspace(named: fixture.targetWorkspaceName)
        _ = manager.setManagedFocus(fixture.anchorToken, in: fixture.targetWorkspaceId, onMonitor: fixture.monitor.id)
        _ = manager.confirmManagedFocus(
            fixture.anchorToken,
            in: fixture.targetWorkspaceId,
            onMonitor: fixture.monitor.id,
            activateWorkspaceOnMonitor: true
        )
    }

    private func summonResponse(_ fixture: Fixture, mark: String) -> IPCResponse {
        IPCWindowMarkRequestExecutor(controller: fixture.controller).response(
            for: .summon(name: mark),
            id: "summon-\(mark)"
        )
    }
}
