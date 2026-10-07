// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension WMController {
    func isFrontmostAppLockScreen() -> Bool {
        lockScreenObserver.isFrontmostAppLockScreen()
    }

    func isPointInOwnWindow(_ point: CGPoint) -> Bool {
        ownedWindowRegistry.contains(point: point)
    }

    var hasFrontmostOwnedWindow: Bool {
        ownedWindowRegistry.hasFrontmostWindow
    }

    var hasVisibleOwnedWindow: Bool {
        ownedWindowRegistry.hasVisibleWindow
    }

    func releaseStaleOwnedSurfaceFocus() {
        guard workspaceManager.nativeFocusOwner == .ownedSurface, !hasVisibleOwnedWindow else { return }
        workspaceManager.clearNativeFocusOwner()
    }

    func isOwnedWindow(windowNumber: Int) -> Bool {
        ownedWindowRegistry.contains(windowNumber: windowNumber)
    }

    var isSystemModalFocusActive: Bool {
        guard let systemModalFocusToken = workspaceManager.systemModalFocusToken else { return false }
        return systemModalFocusToken == workspaceManager.nativeManagedFocusToken
    }

    var shouldSuppressManagedFocusRecovery: Bool {
        guard focusPolicyEngine.evaluate(.managedFocusRecovery).allowsFocusChange else { return true }
        if isSystemModalFocusActive { return true }
        switch workspaceManager.nativeFocusOwner {
        case .external,
             .ownedSurface:
            return true
        case .managed,
             .none:
            return false
        }
    }

    func canFocusWindow(
        pid: pid_t,
        windowId: Int
    ) -> Bool {
        guard !isLockScreenActive else { return false }
        if hasStartedServices, isFrontmostAppLockScreen() {
            return false
        }
        guard !workspaceManager.isAppHidden(pid: pid) else { return false }
        if let entry = workspaceManager.entry(forWindowId: windowId),
           workspaceManager.isWindowSuppressedByMacOS(entry.token)
        {
            return false
        }
        return focusPolicyEngine.evaluate(.windowFronting).allowsFocusChange
    }

    @discardableResult
    func performWindowFronting(
        pid: pid_t,
        windowId: Int,
        axRef: AXWindowRef
    ) -> Bool {
        guard canFocusWindow(pid: pid, windowId: windowId) else { return false }
        MainThreadAXSpanTrace.measure(.fronting, pid: pid, windowId: windowId) {
            windowFocusOperations.activateApp(pid)
            windowFocusOperations.focusSpecificWindow(pid, UInt32(windowId), axRef.element)
            windowFocusOperations.raiseWindow(axRef.element)
        }
        return true
    }

    @discardableResult
    func submitWindowFocus(pid: pid_t, windowId: Int, axRef: AXWindowRef) -> Bool {
        guard canFocusWindow(pid: pid, windowId: windowId) else { return false }
        windowFocusOperations.submitFocusSpecificWindow(pid, UInt32(windowId), axRef.element)
        return true
    }

    @discardableResult
    func performWindowFocusOnly(
        pid: pid_t,
        windowId: Int,
        axRef: AXWindowRef
    ) -> Bool {
        guard canFocusWindow(pid: pid, windowId: windowId) else { return false }
        windowFocusOperations.focusSpecificWindow(pid, UInt32(windowId), axRef.element)
        return true
    }

    func performWindowOrdering(windowId: Int) {
        if let entry = workspaceManager.entry(forWindowId: windowId),
           workspaceManager.isWindowSuppressedByMacOS(entry.token)
        {
            return
        }
        windowFocusOperations.orderWindow(UInt32(windowId))
    }

    func preferredKeyboardFocusFrame(for token: WindowToken) -> CGRect? {
        if let workspaceId = workspaceManager.entry(for: token)?.workspaceId {
            switch workspaceManager.activeLayoutKind(for: workspaceId) {
            case .niri:
                if let node = niriEngine?.findNode(for: token, in: workspaceId) {
                    return node.renderedFrame ?? node.frame
                }
            case .dwindle:
                if let engine = dwindleEngine {
                    return engine.contentFrame(for: token, in: workspaceId)
                        ?? engine.findNode(for: token, in: workspaceId)?.cachedFrame
                }
            }
        }
        if let floatingState = workspaceManager.floatingState(for: token) {
            return floatingState.lastFrame
        }
        return nil
    }

    func recordNiriCreateFocusTrace(_ kind: NiriCreateFocusTraceEvent.Kind) {
        axEventHandler.recordNiriCreateFocusTrace(.init(kind: kind))
    }

    var isDiscoveryInProgress: Bool {
        layoutRefreshController.isDiscoveryInProgress
    }

    var isInteractiveGestureActive: Bool {
        mouseEventHandler.isInteractiveGestureActive
    }
}
