// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class MouseInteractionCleanupTests: NiriInteractionTestCase {
    private struct Fixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let workspace: WorkspaceDescriptor.ID
        let window: NiriWindow
    }

    @MainActor
    func testCleanupReconcilesMoveEngineAndLocalState() throws {
        let fixture = try makeFixture(pid: 1_021)
        let beganMove = fixture.controller.workspaceManager.withEngineMutationScope(in: fixture.workspace) {
            beginMove(fixture.engine, window: fixture.window, in: fixture.workspace)
        }
        XCTAssertTrue(beganMove)
        let handler = fixture.controller.mouseEventHandler
        handler.state.isMoving = true
        handler.state.activeInteractionSource = .trackpadGesture

        handler.cleanup()

        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertFalse(handler.state.isMoving)
        XCTAssertNil(handler.state.activeInteractionButton)
        XCTAssertFalse(handler.isInteractiveGestureActive)
    }

    @MainActor
    func testInputSuppressionReconcilesResizeEngineAndLocalState() throws {
        let fixture = try makeFixture(pid: 1_022)
        XCTAssertTrue(beginResize(fixture.engine, window: fixture.window, in: fixture.workspace))
        let handler = fixture.controller.mouseEventHandler
        handler.state.isResizing = true
        handler.state.resizeLayout = .niri
        handler.state.activeInteractionSource = .trackpadGesture
        handler.state.currentHoveredEdges = .right
        let resize = try XCTUnwrap(fixture.engine.interactiveResize)
        XCTAssertTrue(
            fixture.engine.interactiveResizeUpdate(
                currentLocation: CGPoint(
                    x: resize.startMouseLocation.x + 100,
                    y: resize.startMouseLocation.y
                ),
                monitorFrame: workingFrame,
                gaps: LayoutGaps(horizontal: 0, vertical: 0)
            )
        )
        let worldSeqBeforeCancellation = fixture.controller.workspaceManager.worldSeq

        fixture.controller.isLockScreenActive = true

        XCTAssertNil(fixture.engine.interactiveResize)
        XCTAssertFalse(handler.state.isResizing)
        XCTAssertNil(handler.state.resizeLayout)
        XCTAssertNil(handler.state.activeInteractionButton)
        XCTAssertTrue(handler.state.currentHoveredEdges.isEmpty)
        XCTAssertFalse(handler.isInteractiveGestureActive)
        XCTAssertGreaterThan(fixture.controller.workspaceManager.worldSeq, worldSeqBeforeCancellation)
    }

    @MainActor
    func testCleanupFinalizesResizeWithoutRestartingRefreshAfterServicesStop() throws {
        let fixture = try makeFixture(pid: 1_025)
        XCTAssertTrue(beginResize(fixture.engine, window: fixture.window, in: fixture.workspace))
        let handler = fixture.controller.mouseEventHandler
        handler.state.isResizing = true
        handler.state.resizeLayout = .niri
        handler.state.activeInteractionSource = .trackpadGesture
        fixture.controller.layoutRefreshController.resetState()

        handler.cleanup()

        XCTAssertNil(fixture.engine.interactiveResize)
        XCTAssertFalse(handler.state.isResizing)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.activeRefreshTask)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.activeRefresh)
        XCTAssertNil(fixture.controller.layoutRefreshController.layoutState.pendingRefresh)
    }

    @MainActor
    private func makeFixture(pid: pid_t) throws -> Fixture {
        let controller = makeController()
        controller.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let workspace = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        let window = addWindow(engine, pid: pid, to: workspace)
        return Fixture(controller: controller, engine: engine, workspace: workspace, window: window)
    }

    @MainActor
    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MouseInteractionTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config"),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(directory: root.appendingPathComponent("state"), deferSaves: false),
            autosaveEnabled: false
        )
        return WMController(settings: settings)
    }
}
