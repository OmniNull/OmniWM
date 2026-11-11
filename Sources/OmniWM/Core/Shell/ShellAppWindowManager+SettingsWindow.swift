// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellAppWindowManager {
    struct PendingSettingsWindow {
        weak var window: NSWindow?
        let workspace: WorkspaceDescriptor.ID?
        let shouldClose: () -> Bool
    }

    @discardableResult
    func showSettingsWindow(_ window: NSWindow, shouldClose: @escaping () -> Bool) -> Bool {
        guard controller.hasStartedServices, !isShuttingDown else {
            pendingSettingsWindow = PendingSettingsWindow(
                window: window, workspace: controller.activeWorkspace()?.id, shouldClose: shouldClose
            )
            return false
        }
        pendingSettingsWindow = nil
        let existing = WindowToken(ownWindow: window)
        if windows[existing] === window { return navigateToHostedWindow(existing) }
        guard let token = admitSettingsWindow(window, shouldClose: shouldClose),
              let workspace = controller.workspaceManager.workspace(for: token) else { return false }
        focusAdmittedWindow(token, in: workspace)
        return true
    }

    func admitPendingSettingsWindow() {
        guard let pending = pendingSettingsWindow else { return }
        pendingSettingsWindow = nil
        guard controller.hasStartedServices, !isShuttingDown, let window = pending.window,
              window.isVisible || window.isMiniaturized
        else { return }
        let workspace = pending.workspace.flatMap { controller.workspaceManager.descriptor(for: $0)?.id }
        guard let token = admitSettingsWindow(window, to: workspace, shouldClose: pending.shouldClose),
              let admittedWorkspace = controller.workspaceManager.workspace(for: token) else { return }
        if window.isKeyWindow, navigateToHostedWindow(token) { return }
        controller.layoutRefreshController.requestRelayout(
            reason: .axWindowChanged, affectedWorkspaceIds: [admittedWorkspace]
        )
    }

    @discardableResult
    func admitSettingsWindow(
        _ window: NSWindow,
        to workspace: WorkspaceDescriptor.ID? = nil,
        shouldClose: (() -> Bool)? = nil
    ) -> WindowToken? {
        guard let workspace = workspace ?? controller.activeWorkspace()?.id,
              let token = admit(
                  window, metadata: HostedWindowMetadata(
                      appId: HostedWindowMetadata.settingsAppID, title: window.title, minimumSize: window.minSize,
                      icon: HostedWindowMetadata.settingsIcon, admitsFloating: true
                  ),
                  to: workspace
              ) else { return nil }
        controller.workspaceManager.updateFloatingGeometry(frame: window.frame, for: token)
        controller.ownedWindowRegistry.setManagedFocusRecoverySuppressed(false, for: window)
        closeGuards[token] = shouldClose
        return token
    }

    func isManagedOwnedFocusTarget(activeRequest: ManagedFocusRequest?) -> Bool {
        let keyToken = NSApp?.keyWindow.map { WindowToken(ownWindow: $0) }
        guard let token = keyToken ?? activeRequest?.token ?? controller.workspaceManager.nativeManagedFocusToken,
              token.pid == getpid(), windows[token] != nil
        else { return false }
        return controller.isOwnedWindow(windowNumber: token.windowId)
    }
}
