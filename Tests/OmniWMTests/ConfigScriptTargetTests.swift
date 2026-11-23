// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class ConfigScriptTargetTests: XCTestCase {
    func testContextUsesIPCFocusAndCachedBundleWithoutStartingIPC() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let manager = controller.workspaceManager
        let workspace = try XCTUnwrap(controller.activeWorkspace())
        let token = WindowToken(pid: 71_305, windowId: 305)
        XCTAssertNil(controller.configScriptTarget().context.windowId)
        controller.settings.ipcEnabled = false
        _ = WindowAdmissionTestSupport.track(token, in: workspace.id, controller: controller)
        XCTAssertTrue(manager.setManagedFocus(token, in: workspace.id))
        let session = controller.automationSessionToken
        let info = AppInfoCache.AppInfo(
            name: "Callback fixture",
            bundleId: "test.callback",
            icon: nil,
            activationPolicy: .regular
        )
        let unknown = controller.configScriptTarget()
        XCTAssertEqual(unknown.context.windowId, IPCWindowOpaqueID.encode(token: token, sessionToken: session))
        XCTAssertNil(unknown.context.bundleId)
        XCTAssertFalse(controller.appInfoCache.hasCachedInfo(for: token.pid))
        _ = controller.appInfoCache.info(for: token.pid) { _ in info }
        let known = controller.configScriptTarget().context
        XCTAssertEqual(known.bundleId, info.bundleId)
        XCTAssertEqual(known.workspace, workspace.name)
        XCTAssertEqual(known.layout, manager.activeLayoutKind(for: workspace.id).rawValue)
        XCTAssertEqual(known.windowId, unknown.context.windowId)
    }

    func testHostedWindowHasTheSameIDAndAppAsIPCWithoutAProcessCacheEntry() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let manager = controller.workspaceManager
        let workspace = try XCTUnwrap(controller.activeWorkspace())
        let token = WindowToken(pid: getpid(), windowId: 305)
        let metadata = HostedWindowMetadata(
            appId: "test.hosted", title: "Callback fixture", minimumSize: CGSize(width: 200, height: 120)
        )
        let frame = CGRect(origin: .zero, size: metadata.minimumSize)
        XCTAssertEqual(
            manager.addHostedWindow(token: token, metadata: metadata, to: workspace.id, initialFrame: frame),
            token
        )
        _ = manager.setManagedFocus(token, in: workspace.id)
        let context = controller.configScriptTarget().context
        let router = IPCQueryRouter(controller: controller, sessionToken: controller.automationSessionToken)
        let snapshot = try XCTUnwrap(router.focusedWindowResult().window)
        XCTAssertEqual(context.windowId, snapshot.id)
        XCTAssertEqual(context.bundleId, metadata.appId)
        XCTAssertEqual(context.bundleId, snapshot.app?.bundleId)
    }

    func testLayoutMutationRejectsAWindowSelectedBeforeNativeFocusConfirmation() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let manager = controller.workspaceManager
        let workspace = try XCTUnwrap(controller.activeWorkspace())
        controller.settings.workspaces.configurations = [WorkspaceConfiguration(
            name: workspace.name,
            layoutType: .niri
        )]
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let first = WindowToken(pid: 71_305, windowId: 305)
        let second = WindowToken(pid: first.pid, windowId: first.windowId + 1)
        _ = WindowAdmissionTestSupport.track(first, in: workspace.id, controller: controller)
        _ = WindowAdmissionTestSupport.track(second, in: workspace.id, controller: controller)
        let firstNode = engine.addWindow(token: first, to: workspace.id, afterSelection: nil)
        let secondNode = engine.addWindow(token: second, to: workspace.id, afterSelection: firstNode.id)
        _ = manager.setManagedFocus(first, in: workspace.id)
        let target = controller.configScriptTarget()
        manager.withNiriViewportState(for: workspace.id) { $0.selectedNodeId = secondNode.id }
        let column = try XCTUnwrap(engine.findColumn(containing: secondNode, in: workspace.id))
        let before = column.width
        let resize = HotkeyCommand.sizing(.setContainerPrimarySpan(.adjustProportion(12)))
        XCTAssertEqual(manager.nativeManagedFocusToken, first)
        XCTAssertEqual(controller.performConfigScriptCommand(resize, target: target), .staleWindowId)
        XCTAssertEqual(column.width, before)
        _ = manager.beginManagedFocusRequest(second, in: workspace.id, requestId: manager.worldSeq + 1)
        XCTAssertEqual(manager.pendingFocusedToken, second)
        XCTAssertEqual(controller.performConfigScriptCommand(.windowState(.close), target: target), .staleWindowId)
    }

    func testQueuedActionRejectsReplacedFocusRemovedWindowAndRetiredSession() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let manager = controller.workspaceManager
        let workspace = try XCTUnwrap(controller.activeWorkspace())
        let first = WindowToken(pid: 71_305, windowId: 305)
        let second = WindowToken(pid: first.pid, windowId: first.windowId + 1)
        _ = WindowAdmissionTestSupport.track(first, in: workspace.id, controller: controller)
        _ = WindowAdmissionTestSupport.track(second, in: workspace.id, controller: controller)
        let close = HotkeyCommand.windowState(.close)
        XCTAssertEqual(controller.performConfigScriptCommand(close, target: controller.configScriptTarget()), .notFound)
        XCTAssertTrue(manager.setManagedFocus(first, in: workspace.id))
        let target = controller.configScriptTarget()
        XCTAssertTrue(manager.setManagedFocus(second, in: workspace.id))
        XCTAssertEqual(controller.performConfigScriptCommand(close, target: target), .staleWindowId)
        _ = manager.removeWindow(pid: first.pid, windowId: first.windowId)
        XCTAssertEqual(controller.performConfigScriptCommand(close, target: target), .staleWindowId)
        XCTAssertEqual(manager.nativeManagedFocusToken, second)
        XCTAssertNotNil(manager.entry(for: second))
        let previousSession = controller.configScriptTarget()
        _ = IPCServer(controller: controller)
        XCTAssertEqual(
            controller.performConfigScriptCommand(.rescueOffscreenWindows, target: previousSession),
            .staleWindowId
        )
    }
}
