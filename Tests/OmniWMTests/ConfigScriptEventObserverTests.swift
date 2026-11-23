// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
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
                id: IPCWindowOpaqueID.encode(token: token, sessionToken: controller.automationSessionToken),
                bundleId: metadata.appId
            )],
            .monitorFocused: [.init(id: IPCDisplayRef.identifier(fixtureMonitor.id), name: fixtureMonitor.name)]
        ])
        received.removeAll()
        XCTAssertTrue(manager.clearNativeFocusOwner())
        XCTAssertEqual(received, [.windowActive: [.init()]])
    }

    func testObserversAreScopedByKindAndControllerAndDetachOnStop() {
        let controller = InputControllerTestSupport.controller(for: self)
        let other = InputControllerTestSupport.controller(for: self)
        let workspace = WorkspaceDescriptor(name: "Script workspace")
        let postWorkspace = { (sender: WMController) in
            NotificationCenter.default.post(
                name: .omniwmFocusedWorkspaceChanged, object: sender,
                userInfo: [
                    OmniWMFocusNotificationKey.newWorkspaceId: workspace.id,
                    OmniWMFocusNotificationKey.newWorkspaceName: workspace.name
                ]
            )
        }
        var events: [ConfigScriptEventPayload] = []
        let observers = ConfigScriptEventObservers(controller: controller, kinds: [.workspaceActive]) { kind, payload in
            XCTAssertEqual(kind, .workspaceActive)
            events.append(payload)
        }
        XCTAssertNil(controller.scriptModeObserver)
        postWorkspace(other)
        NotificationCenter.default.post(name: .omniwmFocusedMonitorChanged, object: controller)
        NotificationCenter.default.post(name: .omniwmFocusChanged, object: controller)
        XCTAssertTrue(events.isEmpty)
        postWorkspace(controller)
        let expected = [ConfigScriptEventPayload(id: workspace.id.uuidString, name: workspace.name)]
        XCTAssertEqual(events, expected)
        observers.stop()
        postWorkspace(controller)
        XCTAssertEqual(events, expected)
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
