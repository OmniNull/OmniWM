// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMAutomation
import OmniWMIPC
import XCTest

@MainActor
final class ConfigScriptEventObserverTests: XCTestCase {
    func testFocusDispatcherDeliversNativeIdentitiesAndClearedWindow() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let manager = controller.workspaceManager
        let fixtureMonitor = try XCTUnwrap(manager.monitors.first)
        let workspace = try XCTUnwrap(controller.activeWorkspace())
        _ = manager.setActiveWorkspace(workspace.id, on: fixtureMonitor.id)
        let token = WindowToken(pid: getpid(), windowId: Int(getpid()))
        let metadata = HostedWindowMetadata(
            appId: "test.events.document", title: "Event fixture", minimumSize: CGSize(width: 200, height: 120)
        )
        XCTAssertEqual(manager.addHostedWindow(
            token: token, metadata: metadata, to: workspace.id,
            initialFrame: CGRect(origin: .zero, size: metadata.minimumSize)
        ), token)
        _ = manager.setManagedFocus(token, in: workspace.id, onMonitor: fixtureMonitor.id)

        var received: [ConfigScriptEventKind: [ConfigScriptEventPayload]] = [:]
        let observers = ConfigScriptEventObservers(
            controller: controller,
            kinds: [.workspaceActive, .windowActive, .monitorFocused]
        ) {
            received[$0, default: []].append($1)
        }
        defer { observers.stop() }
        let dispatcher = FocusNotificationDispatcher(controller: controller)
        dispatcher.notifyFocusChangesIfNeeded()
        dispatcher.notifyFocusChangesIfNeeded()
        XCTAssertEqual(received, [
            .workspaceActive: [.init(id: workspace.id.uuidString, name: workspace.name)],
            .windowActive: [.init(
                id: ConfigScriptWindowID.string(token, session: controller.scriptSession.identity),
                bundleId: metadata.appId
            )],
            .monitorFocused: [.init(id: fixtureMonitor.id.scriptIdentifier, name: fixtureMonitor.name)]
        ])
        received.removeAll()
        XCTAssertTrue(manager.clearNativeFocusOwner())
        XCTAssertEqual(received, [.windowActive: [.init()]])
    }

    func testObserversAreScopedByKindAndControllerAndDetachOnStop() throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let other = InputControllerTestSupport.controller(for: self)
        let workspace = try XCTUnwrap(controller.activeWorkspace())
        var events: [ConfigScriptEventPayload] = []
        let observers = ConfigScriptEventObservers(controller: controller, kinds: [.workspaceActive]) { kind, payload in
            XCTAssertEqual(kind, .workspaceActive)
            events.append(payload)
        }
        XCTAssertNil(controller.scriptModeObserver)
        XCTAssertNil(controller.scriptFocusObservers.monitor)
        XCTAssertNil(controller.scriptFocusObservers.window)
        FocusNotificationDispatcher(controller: other).notifyFocusChangesIfNeeded()
        XCTAssertTrue(events.isEmpty)
        FocusNotificationDispatcher(controller: controller).notifyFocusChangesIfNeeded()
        let expected = [ConfigScriptEventPayload(id: workspace.id.uuidString, name: workspace.name)]
        XCTAssertEqual(events, expected)
        observers.stop()
        FocusNotificationDispatcher(controller: controller).notifyFocusChangesIfNeeded()
        XCTAssertEqual(events, expected)
    }

    func testNativeObserverCanPublishAnotherWorkspaceDuringDelivery() throws {
        try checkReentrantDelivery(nativeFirst: false)
        try checkReentrantDelivery(nativeFirst: true)
    }

    private func checkReentrantDelivery(nativeFirst: Bool) throws {
        let controller = InputControllerTestSupport.controller(for: self)
        let manager = controller.workspaceManager
        manager.onSessionStateChanged = nil
        let monitor = try XCTUnwrap(manager.monitors.first).id
        _ = manager.setInteractionMonitor(monitor)
        let first = try XCTUnwrap(controller.activeWorkspace())
        let nextName = WorkspaceIDPolicy.lowestUnusedRawID(in: manager.sortedWorkspaces().map(\.name))
        let next = try XCTUnwrap(manager.createDynamicWorkspace(named: nextName, on: monitor))
        let dispatcher = FocusNotificationDispatcher(controller: controller)
        var scriptIDs: [String] = []
        let native = WorkspaceNotificationProbe()
        let center = NotificationCenter.default
        func registerNative() {
            center.addObserver(
                native,
                selector: #selector(WorkspaceNotificationProbe.receive),
                name: .omniwmFocusedWorkspaceChanged,
                object: controller
            )
        }
        if nativeFirst { registerNative() }
        let registration = ConfigScriptEventObservers(controller: controller, kinds: [.workspaceActive]) { _, payload in
            if let id = payload.id { scriptIDs.append(id) }
        }
        if !nativeFirst { registerNative() }
        defer {
            registration.stop()
            center.removeObserver(native)
        }
        native.firstDelivery = {
            XCTAssertTrue(manager.setActiveWorkspace(next.id, on: monitor))
            dispatcher.notifyFocusChangesIfNeeded()
        }
        dispatcher.notifyFocusChangesIfNeeded()
        XCTAssertEqual(native.ids, [first.id, next.id])
        let expectedOrder = nativeFirst ? [next.id, first.id] : [first.id, next.id]
        XCTAssertEqual(scriptIDs, expectedOrder.map(\.uuidString))
    }

    func testSynchronousDeliveryMayReplaceTheSubscribedRegistration() {
        let controller = InputControllerTestSupport.controller(for: self)
        var events: [String?] = []
        var replacement: ConfigScriptEventObservers?
        let original = ConfigScriptEventObservers(controller: controller, kinds: [.workspaceActive]) { _, payload in
            events.append(payload.name)
            replacement = ConfigScriptEventObservers(controller: controller, kinds: [.workspaceActive]) { _, next in
                events.append(next.name)
            }
            ConfigScriptEventObservers.workspaceChanged(nil, name: "nested", controller: controller)
        }
        defer { replacement?.stop() }
        ConfigScriptEventObservers.workspaceChanged(nil, name: "outer", controller: controller)
        original.stop()
        XCTAssertTrue(controller.scriptFocusObservers.workspace === replacement)
        XCTAssertEqual(events, ["outer", "nested"])
    }

    func testOnlyChangedNativeKeyboardModeIsDeliveredAndRemovalUnhooksIt() {
        let controller = InputControllerTestSupport.controller(for: self)
        var modes: [ConfigScriptEventPayload] = []
        let observers = ConfigScriptEventObservers(controller: controller, kinds: [.keybindsSubmap]) { kind, payload in
            XCTAssertEqual(kind, .keybindsSubmap)
            modes.append(payload)
        }
        XCTAssertTrue(controller.scriptModeObserver === observers)
        controller.hotkeys.keyboardModeInput.state = .window
        controller.keyboardModeKind = .window
        XCTAssertEqual(controller.performKeyboardModeCommand(.exit), .executed)
        XCTAssertEqual(controller.performKeyboardModeCommand(.exit), .noChange)
        let expected = [ConfigScriptEventPayload(name: KeyboardModeKind.normal.rawValue)]
        XCTAssertEqual(modes, expected)
        observers.stop()
        XCTAssertNil(controller.scriptModeObserver)
        controller.hotkeys.keyboardModeInput.state = .window
        XCTAssertEqual(controller.performKeyboardModeCommand(.exit), .executed)
        XCTAssertEqual(modes, expected)
    }
}

@MainActor
private final class WorkspaceNotificationProbe: NSObject {
    private(set) var ids: [WorkspaceDescriptor.ID] = []
    var firstDelivery: (() -> Void)?

    @objc func receive(_ notification: NSNotification) {
        let id = notification.userInfo?[OmniWMFocusNotificationKey.newWorkspaceId] as? WorkspaceDescriptor.ID
        if let id { ids.append(id) }
        let callback = firstDelivery
        firstDelivery = nil
        callback?()
    }
}
