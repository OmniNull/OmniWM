// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class FullscreenToggleRaiseTests: XCTestCase {
    private enum FocusOperation: Equatable {
        case focus(WindowToken)
        case raise
    }

    private final class FocusRecorder {
        var operations: [FocusOperation] = []
    }

    func testNiriFullscreenToggleFrontsAndRaisesTheWindowAfterLayout() throws {
        let recorder = FocusRecorder()
        let controller = makeController(recorder: recorder)
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.layoutRefreshController.resetState()
        let engine = try XCTUnwrap(controller.niriEngine)
        let first = addWindow(pid: 830_001, windowId: 830_101, to: workspaceId, controller: controller)
        let second = addWindow(pid: 830_001, windowId: 830_102, to: workspaceId, controller: controller)
        _ = engine.addWindow(token: first, to: workspaceId, afterSelection: nil)
        let secondNode = engine.addWindow(token: second, to: workspaceId, afterSelection: nil)
        _ = controller.workspaceManager.commitWorkspaceSelection(
            nodeId: secondNode.id,
            focusedToken: second,
            in: workspaceId,
            onMonitor: controller.workspaceManager.monitorId(for: workspaceId)
        )
        _ = controller.workspaceManager.setManagedFocus(second, in: workspaceId)

        for expectedFullscreen in [true, false] {
            recorder.operations.removeAll()
            let blocker = try LayoutRefreshTestSupport.block(controller, in: workspaceId, reason: .layoutCommand)
            defer { LayoutRefreshTestSupport.unblock(controller, blocker: blocker) }

            XCTAssertEqual(controller.commandHandler.performCommand(.fullscreen(.managed)), .executed)
            XCTAssertEqual(secondNode.isFullscreen, expectedFullscreen)
            XCTAssertTrue(recorder.operations.isEmpty)

            let postLayout = try XCTUnwrap(
                controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
            )
            XCTAssertTrue(postLayout.isCurrent(using: controller.workspaceManager))
            postLayout.runIfCurrent(using: controller.workspaceManager)
            XCTAssertEqual(recorder.operations, [.focus(second), .raise])
        }
    }

    func testDwindleFullscreenToggleFrontsAndRaisesTheWindowAfterLayout() throws {
        let recorder = FocusRecorder()
        let controller = makeController(recorder: recorder)
        let workspaceName = "96"
        controller.settings.workspaces.configurations.append(
            WorkspaceConfiguration(name: workspaceName, layoutType: .dwindle)
        )
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: workspaceName))
        _ = controller.workspaceManager.focusWorkspace(named: workspaceName)
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let engine = try XCTUnwrap(controller.dwindleEngine)
        controller.layoutRefreshController.resetState()
        let first = addWindow(pid: 830_002, windowId: 830_201, to: workspaceId, controller: controller)
        let second = addWindow(pid: 830_002, windowId: 830_202, to: workspaceId, controller: controller)
        let screen = controller.workspaceManager.monitor(for: workspaceId)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        controller.workspaceManager.withEngineMutationScope {
            _ = engine.addWindow(token: first, to: workspaceId, activeWindowFrame: nil)
            _ = engine.addWindow(token: second, to: workspaceId, activeWindowFrame: nil)
            _ = engine.calculateLayout(for: workspaceId, screen: screen)
        }
        controller.layoutRefreshController.resetState()
        let selected = try XCTUnwrap(engine.activeToken(in: workspaceId))
        _ = controller.workspaceManager.setManagedFocus(selected, in: workspaceId)

        let blocker = try LayoutRefreshTestSupport.block(controller, in: workspaceId, reason: .layoutCommand)
        defer { LayoutRefreshTestSupport.unblock(controller, blocker: blocker) }

        XCTAssertEqual(controller.commandHandler.performCommand(.fullscreen(.managed)), .executed)
        XCTAssertTrue(recorder.operations.isEmpty)

        let postLayout = try XCTUnwrap(
            controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
        )
        XCTAssertTrue(postLayout.isCurrent(using: controller.workspaceManager))
        postLayout.runIfCurrent(using: controller.workspaceManager)
        XCTAssertEqual(recorder.operations, [.focus(selected), .raise])
    }

    private func makeController(recorder: FocusRecorder) -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMFullscreenToggleRaiseTests-\(UUID().uuidString)", isDirectory: true)
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
        return WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { pid, windowId, _ in
                    recorder.operations.append(.focus(WindowToken(pid: pid, windowId: Int(windowId))))
                },
                raiseWindow: { _ in recorder.operations.append(.raise) }
            )
        )
    }

    private func addWindow(
        pid: pid_t,
        windowId: Int,
        to workspaceId: WorkspaceDescriptor.ID,
        controller: WMController
    ) -> WindowToken {
        controller.workspaceManager.addWindow(
            AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
            pid: pid,
            windowId: windowId,
            to: workspaceId
        )
    }
}
