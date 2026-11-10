// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
extension HostedSettingsWindowTests {
    func testSettingsShownBeforeServicesStartIsShownUnmanagedThenAdmittedWhenServicesStart() throws {
        let fixture = try HostedSettingsWindowFixture()
        defer { fixture.close() }
        fixture.controller.hasStartedServices = false
        let settings = fixture.makeSettingsController()

        settings.show(settings: fixture.controller.settings, controller: fixture.controller)

        let window = try XCTUnwrap(settings.window)
        let token = WindowToken(ownWindow: window)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(fixture.registry.contains(windowNumber: window.windowNumber))
        XCTAssertTrue(fixture.manager.windows.isEmpty)
        XCTAssertNil(fixture.controller.workspaceManager.entry(for: token))

        settings.show(settings: fixture.controller.settings, controller: fixture.controller)

        XCTAssertTrue(settings.window === window)
        XCTAssertTrue(fixture.manager.windows.isEmpty)

        fixture.controller.hasStartedServices = true
        fixture.manager.admitPendingSettingsWindow()

        XCTAssertTrue(fixture.manager.windows[token] === window)
        let entry = try XCTUnwrap(fixture.controller.workspaceManager.entry(for: token))
        XCTAssertEqual(entry.mode, .floating)
        XCTAssertEqual(entry.workspaceId, fixture.first)
        XCTAssertEqual(entry.target.hostedMetadata?.appId, HostedWindowMetadata.settingsAppID)
        XCTAssertEqual(entry.target.hostedMetadata?.title, window.title)
        XCTAssertEqual(entry.target.hostedMetadata?.minimumSize, window.minSize)
    }

    func testReshowingAnAdmittedSettingsWindowFocusesItWithoutASecondEntry() async throws {
        let fixture = try HostedSettingsWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let settings = fixture.makeSettingsController()
        settings.show(settings: controller.settings, controller: controller)
        let window = try XCTUnwrap(settings.window)
        let token = WindowToken(ownWindow: window)
        XCTAssertTrue(fixture.manager.windows[token] === window)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
        if let request = controller.intentLedger.activeManagedRequest {
            _ = controller.cancelManagedFocusRequest(request)
        }
        let external = WindowToken(pid: 114_001, windowId: 114_101)
        _ = WindowAdmissionTestSupport.track(external, in: fixture.first, controller: controller)
        XCTAssertTrue(controller.workspaceManager.confirmManagedFocus(
            external, in: fixture.first, onMonitor: fixture.monitor.id, activateWorkspaceOnMonitor: true
        ))

        settings.show(settings: controller.settings, controller: controller)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        XCTAssertTrue(settings.window === window)
        XCTAssertEqual(fixture.manager.windows.count, 1)
        XCTAssertEqual(controller.workspaceManager.allEntries().filter { $0.windowId == token.windowId }.count, 1)
        XCTAssertEqual(
            controller.workspaceManager.pendingFocusedToken ?? controller.workspaceManager.nativeManagedFocusToken,
            token
        )
    }

    func testFirstShowWithServicesStartedAdmitsAndFocusesSettingsOnTheActiveWorkspace() async throws {
        for layout in [LayoutType.niri, .dwindle] {
            let fixture = try HostedSettingsWindowFixture(layout: layout)
            defer { fixture.close() }
            let controller = fixture.controller
            await fixture.activate(fixture.second)
            let settings = fixture.makeSettingsController()

            settings.show(settings: controller.settings, controller: controller)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

            let window = try XCTUnwrap(settings.window)
            let token = WindowToken(ownWindow: window)
            XCTAssertTrue(fixture.manager.windows[token] === window)
            let entry = try XCTUnwrap(controller.workspaceManager.entry(for: token))
            XCTAssertEqual(entry.workspaceId, fixture.second)
            XCTAssertEqual(entry.mode, .floating)
            XCTAssertNil(controller.workspaceManager.hiddenState(for: token))
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(controller.activeWorkspace()?.id, fixture.second)
            XCTAssertEqual(
                controller.workspaceManager.pendingFocusedToken ?? controller.workspaceManager.nativeManagedFocusToken,
                token
            )
        }
    }

    func testShowingSettingsHiddenOnAnInactiveWorkspaceSwitchesToItRevealsAndFocusesIt() async throws {
        for layout in [LayoutType.niri, .dwindle] {
            let fixture = try HostedSettingsWindowFixture(layout: layout)
            defer { fixture.close() }
            let controller = fixture.controller
            let settings = fixture.makeSettingsController()
            settings.show(settings: controller.settings, controller: controller)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
            let window = try XCTUnwrap(settings.window)
            let token = WindowToken(ownWindow: window)
            XCTAssertEqual(controller.workspaceManager.entry(for: token)?.workspaceId, fixture.first)
            if let request = controller.intentLedger.activeManagedRequest {
                _ = controller.cancelManagedFocusRequest(request)
            }
            await fixture.activate(fixture.second)
            XCTAssertFalse(window.isVisible)
            XCTAssertEqual(controller.workspaceManager.hiddenState(for: token)?.reason, .workspaceInactive)
            let nativeFocusCount = fixture.nativelyFocused.count

            settings.show(settings: controller.settings, controller: controller)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

            XCTAssertTrue(settings.window === window)
            XCTAssertEqual(fixture.manager.windows.count, 1)
            XCTAssertEqual(controller.activeWorkspace()?.id, fixture.first)
            XCTAssertNil(controller.workspaceManager.hiddenState(for: token))
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(
                controller.workspaceManager.pendingFocusedToken ?? controller.workspaceManager.nativeManagedFocusToken,
                token
            )
            XCTAssertEqual(fixture.nativelyFocused.dropFirst(nativeFocusCount).last, token)
        }
    }

    func testReturningToTheSettingsWorkspaceFrontsSettingsThroughNativeFocus() async throws {
        for layout in [LayoutType.niri, .dwindle] {
            let fixture = try HostedSettingsWindowFixture(layout: layout)
            defer { fixture.close() }
            let controller = fixture.controller
            let settings = fixture.makeSettingsController()
            settings.show(settings: controller.settings, controller: controller)
            await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
            let token = WindowToken(ownWindow: try XCTUnwrap(settings.window))
            XCTAssertTrue(controller.workspaceNavigationHandler.switchWorkspace(rawWorkspaceID: "2"))
            await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
            let nativeFocusCount = fixture.nativelyFocused.count

            XCTAssertTrue(controller.workspaceNavigationHandler.switchWorkspace(rawWorkspaceID: "1"))
            await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

            XCTAssertEqual(controller.activeWorkspace()?.id, fixture.first)
            XCTAssertNil(controller.workspaceManager.hiddenState(for: token))
            XCTAssertEqual(fixture.nativelyFocused.dropFirst(nativeFocusCount).last, token)
            XCTAssertEqual(
                controller.workspaceManager.pendingFocusedToken ?? controller.workspaceManager.nativeManagedFocusToken,
                token
            )
        }
    }

    func testSettingsShownBeforeServicesStartIsAdmittedOnTheWorkspaceItWasShownOn() throws {
        let fixture = try HostedSettingsWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.hasStartedServices = false
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(fixture.second, on: fixture.monitor.id))
        let settings = fixture.makeSettingsController()
        settings.show(settings: controller.settings, controller: controller)
        let window = try XCTUnwrap(settings.window)
        let token = WindowToken(ownWindow: window)
        XCTAssertNil(controller.workspaceManager.entry(for: token))
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(fixture.first, on: fixture.monitor.id))

        controller.hasStartedServices = true
        fixture.manager.admitPendingSettingsWindow()

        XCTAssertTrue(fixture.manager.windows[token] === window)
        XCTAssertEqual(controller.workspaceManager.entry(for: token)?.workspaceId, fixture.second)
        XCTAssertNil(fixture.manager.pendingSettingsWindow)
    }

    func testPendingKeySettingsWindowIsRevealedAndFocusedOnItsWorkspaceWhenServicesStart() async throws {
        for layout in [LayoutType.niri, .dwindle] {
            let fixture = try HostedSettingsWindowFixture(layout: layout)
            defer { fixture.close() }
            let controller = fixture.controller
            controller.hasStartedServices = false
            XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(fixture.second, on: fixture.monitor.id))
            let window = fixture.makeWindow(reportsKey: true)
            window.orderFront(nil)
            XCTAssertFalse(fixture.manager.showSettingsWindow(window, shouldClose: { true }))
            XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(fixture.first, on: fixture.monitor.id))

            controller.hasStartedServices = true
            fixture.manager.admitPendingSettingsWindow()
            await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

            let token = WindowToken(ownWindow: window)
            XCTAssertEqual(controller.workspaceManager.entry(for: token)?.workspaceId, fixture.second)
            XCTAssertEqual(controller.activeWorkspace()?.id, fixture.second)
            XCTAssertNil(controller.workspaceManager.hiddenState(for: token))
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(
                controller.workspaceManager.pendingFocusedToken ?? controller.workspaceManager.nativeManagedFocusToken,
                token
            )
        }
    }
}
