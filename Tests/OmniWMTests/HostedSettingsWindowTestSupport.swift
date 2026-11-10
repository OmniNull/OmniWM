// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class HostedSettingsKeyWindow: NSWindow {
    override var isKeyWindow: Bool {
        true
    }
}

@MainActor
final class HostedSettingsWindowFixture {
    let title = "OmniWM Settings"
    let minimumSize = CGSize(width: 760, height: 588)
    let registry = OwnedWindowRegistry(surfaceCoordinator: SurfaceCoordinator())
    let controller: WMController
    let first: WorkspaceDescriptor.ID
    let second: WorkspaceDescriptor.ID
    let monitor: Monitor
    private var windows: [NSWindow] = []
    private var settingsControllers: [SettingsWindowController] = []
    private(set) var nativelyFocused: [WindowToken] = []
    var manager: ShellAppWindowManager {
        controller.shellAppWindowManager
    }

    init(layout: LayoutType = .dwindle) throws {
        controller = WindowAdmissionTestSupport.controller(
            prefix: "HostedSettingsWindow", ownedWindowRegistry: registry
        )
        controller.hasStartedServices = true
        controller.shellAppWindowManager.activateApplication = {}
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let display: CGDirectDisplayID = 114_000
        let monitor = Monitor(
            id: .init(displayId: display), displayId: display, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Hosted Settings"
        )
        self.monitor = monitor
        controller.settings.workspaces.configurations = ["1", "2"].map { name in
            WorkspaceConfiguration(
                name: name, monitorAssignment: .specificDisplay(OutputId(from: monitor)), layoutType: layout
            )
        }
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        first = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        second = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "2"))
        let niri = NiriLayoutEngine()
        niri.animationClock = controller.animationClock
        controller.niriEngine = niri
        controller.niriLayoutHandler.syncMonitorsToNiriEngine()
        let dwindle = DwindleLayoutEngine()
        dwindle.animationClock = controller.animationClock
        controller.dwindleEngine = dwindle
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.shellAppWindowManager.focusWithoutRaising = { [weak self] in self?.nativelyFocused.append($0) }
    }

    func makeWindow(reportsKey: Bool = false) -> NSWindow {
        let rect = CGRect(x: 200, y: 100, width: 1040, height: 760)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window: NSWindow = reportsKey
            ? HostedSettingsKeyWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
            : NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.minSize = minimumSize
        registry.register(window)
        windows.append(window)
        return window
    }

    func admit(_ window: NSWindow, shouldClose: (() -> Bool)? = nil) -> WindowToken? {
        manager.admitSettingsWindow(window, shouldClose: shouldClose)
    }

    func makeSettingsController() -> SettingsWindowController {
        let settings = SettingsWindowController(presenter: HostedWindowPresenter(ownedWindowRegistry: registry) {
            $0.orderFront(nil)
        })
        settingsControllers.append(settings)
        return settings
    }

    func activate(_ workspace: WorkspaceDescriptor.ID) async {
        XCTAssertTrue(controller.workspaceManager.setActiveWorkspace(workspace, on: monitor.id))
        controller.layoutRefreshController.commitWorkspaceTransition(
            affectedWorkspaces: [first, second], reason: .workspaceTransition
        )
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)
    }

    func queriedVisibility(of token: WindowToken) -> Bool? {
        IPCWindowQueryProjection(
            controller: controller, sessionToken: "", request: IPCQueryRequest(name: .windows),
            windowOrderedInProvider: { _ in true }
        ).result().windows.first { $0.windowId == token.windowId }?.isVisible
    }

    func close() {
        for window in windows + settingsControllers.compactMap(\.window) {
            window.close()
            registry.unregister(window)
        }
        controller.layoutRefreshController.resetState()
        controller.surfaceReconciler.cleanup()
        controller.axManager.cleanup()
    }
}
