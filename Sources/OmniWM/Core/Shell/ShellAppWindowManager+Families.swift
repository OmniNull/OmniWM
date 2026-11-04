// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellAppWindowManager {
    @discardableResult
    func restoreFamilyIfMinimized(for token: WindowToken) -> Bool {
        guard let parent = controller.workspaceManager.hostedFamilyRoot(for: token), let window = windows[parent]
        else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        return !window.isMiniaturized
    }

    func setFamilyHidden(_ hidden: Bool, requestedBy token: WindowToken) -> Bool {
        let manager = controller.workspaceManager
        guard let parent = manager.hostedFamilyRoot(for: token), let window = windows[parent] else { return false }
        let hidden = (parent == token ? hidden : manager.hiddenState(for: parent) != nil || !window.isVisible)
            || window.isMiniaturized || manager.isWindowSuppressedByMacOS(parent)
        if hidden, window.isVisible {
            for child in childTokens(of: parent) { (windows[child] as? ShellAppNativeWindow)?.finishNativeMove() }
            window.orderOut(nil)
        } else if !hidden, !window.isVisible {
            window.orderFront(nil)
        }
        setContentVisible(!hidden, token: parent)
        for child in childTokens(of: parent) {
            let visible = !hidden && !manager.isWindowSuppressedByMacOS(child)
            if visible, let childWindow = windows[child], !childWindow.isVisible {
                childWindow.orderFront(nil)
            }
            setContentVisible(visible, token: child)
        }
        return true
    }

    func reconcileAttachedGeometry(in workspace: WorkspaceDescriptor.ID) {
        let manager = controller.workspaceManager
        guard let monitor = manager.monitor(for: workspace) else { return }
        for entry in manager.entries(in: workspace) {
            guard let role = entry.target.hostedMetadata?.role, let parent = role.parent,
                  let parentWindow = windows[parent], parentWindow.isVisible, !parentWindow.isMiniaturized,
                  manager.hiddenState(for: parent) == nil, let window = windows[entry.token] else { continue }
            switch role {
            case .main:
                break
            case .sheet:
                manager.observeHostedWindowGeometry(frame: window.frame, for: entry.token)
            case .utility:
                let frame = FloatingFrameGeometry.clamped(window.frame, in: monitor.visibleFrame)
                _ = setFloatingFrame(frame, for: entry.token)
            }
        }
    }
}
