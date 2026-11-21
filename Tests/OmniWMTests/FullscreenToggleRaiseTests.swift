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
        case workerRaise(WindowToken)
    }

    private final class FocusRecorder {
        var operations: [FocusOperation] = []
    }

    private struct Fixture {
        let controller: WMController
        let recorder: FocusRecorder
        let workspaceId: WorkspaceDescriptor.ID
        let toggled: WindowToken
        let other: WindowToken
    }

    func testNiriFullscreenToggleFrontsAndRaisesTheWindowAfterLayout() throws {
        let fixture = try makeNiriFixture()
        let node = try XCTUnwrap(fixture.controller.niriEngine?.findNode(for: fixture.toggled, in: fixture.workspaceId))

        for expectedFullscreen in [true, false] {
            fixture.recorder.operations.removeAll()
            let blocker = try LayoutRefreshTestSupport.block(
                fixture.controller, in: fixture.workspaceId, reason: .layoutCommand
            )
            defer { LayoutRefreshTestSupport.unblock(fixture.controller, blocker: blocker) }

            let postLayout = try toggleFullscreen(fixture)
            XCTAssertEqual(node.isFullscreen, expectedFullscreen)
            XCTAssertTrue(postLayout.isCurrent(using: fixture.controller.workspaceManager))
            postLayout.runIfCurrent(using: fixture.controller.workspaceManager)
            XCTAssertEqual(fixture.recorder.operations, [.focus(fixture.toggled), .workerRaise(fixture.toggled)])
        }
    }

    func testDwindleFullscreenToggleFrontsAndRaisesTheWindowAfterLayout() throws {
        let fixture = try makeDwindleFixture()
        let blocker = try LayoutRefreshTestSupport.block(
            fixture.controller, in: fixture.workspaceId, reason: .layoutCommand
        )
        defer { LayoutRefreshTestSupport.unblock(fixture.controller, blocker: blocker) }

        let postLayout = try toggleFullscreen(fixture)
        XCTAssertTrue(postLayout.isCurrent(using: fixture.controller.workspaceManager))
        postLayout.runIfCurrent(using: fixture.controller.workspaceManager)
        XCTAssertEqual(fixture.recorder.operations, [.focus(fixture.toggled), .workerRaise(fixture.toggled)])
    }

    func testFullscreenToggleLeavesFocusThatMovedBeforeItsLayout() throws {
        for usesDwindle in [false, true] {
            for nativeFocusChange in [false, true] {
                let fixture = try usesDwindle ? makeDwindleFixture() : makeNiriFixture()
                let blocker = try LayoutRefreshTestSupport.block(
                    fixture.controller, in: fixture.workspaceId, reason: .layoutCommand
                )
                defer { LayoutRefreshTestSupport.unblock(fixture.controller, blocker: blocker) }

                let postLayout = try toggleFullscreen(fixture)
                if nativeFocusChange {
                    XCTAssertTrue(fixture.controller.workspaceManager.setManagedFocus(
                        fixture.other, in: fixture.workspaceId
                    ))
                } else {
                    XCTAssertNotNil(fixture.controller.focusWindow(fixture.other))
                }
                let operationsBeforeAction = fixture.recorder.operations
                XCTAssertFalse(
                    postLayout.isCurrent(using: fixture.controller.workspaceManager),
                    "dwindle=\(usesDwindle), native=\(nativeFocusChange)"
                )
                postLayout.runIfCurrent(using: fixture.controller.workspaceManager)
                XCTAssertEqual(fixture.recorder.operations, operationsBeforeAction)
            }
        }
    }

    private func toggleFullscreen(_ fixture: Fixture) throws -> RefreshPostLayoutAction {
        XCTAssertEqual(fixture.controller.commandHandler.performCommand(.fullscreen(.managed)), .executed)
        XCTAssertTrue(fixture.recorder.operations.isEmpty)
        return try XCTUnwrap(
            fixture.controller.layoutRefreshController.layoutState.pendingRefresh?.postLayoutActions.first
        )
    }

    private func makeNiriFixture() throws -> Fixture {
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
        return Fixture(
            controller: controller, recorder: recorder, workspaceId: workspaceId, toggled: second, other: first
        )
    }

    private func makeDwindleFixture() throws -> Fixture {
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
        let screen = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId)).visibleFrame
        controller.workspaceManager.withEngineMutationScope {
            _ = engine.addWindow(token: first, to: workspaceId, activeWindowFrame: nil)
            _ = engine.addWindow(token: second, to: workspaceId, activeWindowFrame: nil)
            _ = engine.calculateLayout(for: workspaceId, screen: screen)
        }
        controller.layoutRefreshController.resetState()
        let selected = try XCTUnwrap(engine.activeToken(in: workspaceId))
        _ = controller.workspaceManager.setManagedFocus(selected, in: workspaceId)
        return Fixture(
            controller: controller, recorder: recorder, workspaceId: workspaceId,
            toggled: selected, other: selected == first ? second : first
        )
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
                raiseWindow: { _ in recorder.operations.append(.raise) },
                enqueueRetryRaise: { pid, window, _, _, _ in
                    recorder.operations.append(.workerRaise(WindowToken(pid: pid, windowId: window.windowId)))
                    return true
                }
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
