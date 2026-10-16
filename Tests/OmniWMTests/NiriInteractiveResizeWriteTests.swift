// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriInteractiveResizeWriteTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let monitor: Monitor
        let workspaceId: WorkspaceDescriptor.ID
        let engine: NiriLayoutEngine
        let tokens: [WindowToken]

        @MainActor func plan() throws -> WorkspaceLayoutPlan {
            let handler = controller.layoutRefreshController.niriHandler
            let snapshot = try XCTUnwrap(handler.makeWorkspaceSnapshot(
                workspaceId: workspaceId,
                monitor: monitor,
                options: .init(
                    viewportState: controller.workspaceManager.niriViewportState(for: workspaceId),
                    useScrollAnimationPath: true,
                    removalSeed: nil,
                    isActiveWorkspace: true
                )
            ))
            return handler.buildOnDemandLayoutPlan(
                snapshot: snapshot, engine: engine, monitor: monitor, animationTime: nil, settlesAnimation: false
            )
        }
    }

    func testInteractiveResizeMovesUnchangedNeighborsWithPositionOnlyWrites() throws {
        let fixture = try makeFixture(windowCount: 3)
        let settled = try fixture.plan()
        XCTAssertFalse(settled.isInteractiveResize)
        for change in settled.diff.frameChanges {
            fixture.controller.axManager.confirmFrameWrite(for: change.token.windowId, frame: change.frame)
        }

        let resized = try XCTUnwrap(fixture.engine.findNode(for: fixture.tokens[0], in: fixture.workspaceId))
        let frame = try XCTUnwrap(resized.renderedFrame ?? resized.frame)
        let start = CGPoint(x: frame.maxX - 2, y: frame.midY)
        let mouse = fixture.controller.mouseEventHandler
        XCTAssertTrue(mouse.beginNiriResize(
            window: resized, engine: fixture.engine, wsId: fixture.workspaceId, at: start, source: .mouse(.right)
        ))
        mouse.updateManagedResize(at: CGPoint(x: start.x + 120, y: start.y))

        let interactive = try fixture.plan()
        XCTAssertTrue(interactive.isInteractiveResize)
        let components = Dictionary(
            interactive.diff.frameChanges.map { ($0.token, $0.components) },
            uniquingKeysWith: { $1 }
        )
        XCTAssertEqual(components[fixture.tokens[0]], .all)
        let movedNeighbors = fixture.tokens.dropFirst().filter { components[$0] != nil }
        XCTAssertFalse(movedNeighbors.isEmpty)
        for token in movedNeighbors {
            XCTAssertEqual(components[token], .position)
        }
    }

    private func makeFixture(windowCount: Int) throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMNiriInteractiveResizeWriteTests")
        let monitor = Monitor(
            id: .init(displayId: 91),
            displayId: 91,
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410),
            hasNotch: false,
            name: "Main"
        )
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let pid: pid_t = 961_001
        let tokens = (0 ..< windowCount).map { index in
            let windowId = 961_101 + index
            let token = controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid, windowId: windowId, to: workspaceId
            )
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
            return token
        }
        return Fixture(
            controller: controller, monitor: monitor, workspaceId: workspaceId, engine: engine, tokens: tokens
        )
    }
}
