// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellAppWindowManager {
    private struct RegisteredWindow {
        let token: WindowToken
        let window: NSWindow
        let entry: WindowState
    }

    func contentSize(of window: NSWindow) -> CGSize {
        window.contentView?.bounds.size ?? window.contentRect(forFrameRect: window.frame).size
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard let registered = registeredWindow(in: notification) else { return }
        let token = registered.token
        let window = registered.window
        let entry = registered.entry
        guard controller.hasStartedServices, !applyingFrames.contains(token), entry.mode == .tiling else { return }
        liveResizeStarts[token] = window.frame
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let registered = registeredWindow(in: notification) else { return }
        let token = registered.token
        let window = registered.window
        let entry = registered.entry
        guard let start = liveResizeStarts[token] else { return }
        defer { liveResizeStarts.removeValue(forKey: token) }
        observeNativeGeometry(window, token: token)
        guard controller.hasStartedServices, entry.mode == .tiling else { return }
        if !controller.mouseEventHandler.adoptHostedNativeResize(entry, from: start, to: window.frame) {
            controller.layoutRefreshController.requestRelayout(
                reason: .axWindowChanged, affectedWorkspaceIds: [entry.workspaceId]
            )
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let registered = registeredWindow(in: notification) else { return }
        let token = registered.token
        let window = registered.window
        resizeContent(of: token, window: window)
        observeNativeGeometry(window, token: token)
    }

    func windowDidMove(_ notification: Notification) {
        guard let registered = registeredWindow(in: notification) else { return }
        let token = registered.token
        let window = registered.window
        observeNativeGeometry(window, token: token)
    }

    func windowWillMove(_ notification: Notification) {
        (notification.object as? ShellAppNativeWindow)?.detachForNativeMove()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard controller.hasStartedServices,
              let registered = registeredWindow(in: notification), registered.window.isKeyWindow else { return }
        let token = registered.token
        let window = registered.window
        let entry = registered.entry
        guard activeSheet(for: token).map({ $0 == token }) ?? true else { return }
        if let request = controller.intentLedger.activeManagedRequest, request.token != token {
            guard isDirectFocusEvent(for: window) else { return }
            controller.cancelManagedFocusRequest(request)
        }
        let request = controller.intentLedger.activeManagedRequest(for: token)
        guard controller.workspaceManager.canConfirmManagedFocus(
            token, in: entry.workspaceId, requestId: request?.requestId
        ) else { return }
        let monitorId = controller.workspaceManager.monitorId(for: entry.workspaceId)
        let isActive = monitorId.map { controller.workspaceManager.activeWorkspace(on: $0)?.id == entry.workspaceId }
            ?? false
        controller.axEventHandler.handleManagedAppActivation(
            entry: entry, isWorkspaceActive: isActive, appFullscreen: false,
            source: .focusedWindowChanged, activeRequestId: request?.requestId, bindCurrentPidRequest: false
        )
    }

    func windowDidMiniaturize(_ notification: Notification) {
        updateMinimized(true, notification: notification)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updateMinimized(false, notification: notification)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let registered = registeredWindow(in: notification) else { return }
        let token = registered.token
        let window = registered.window
        setContentVisible(
            window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible), token: token
        )
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        updateDisplayContext(notification)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateDisplayContext(notification)
    }

    private func updateDisplayContext(_ notification: Notification) {
        guard let registered = registeredWindow(in: notification) else { return }
        slot(for: registered.token)?.surface.updateDisplayContext(scale: registered.window.backingScaleFactor)
    }

    private func registeredWindow(in notification: Notification) -> RegisteredWindow? {
        guard !isShuttingDown, let window = notification.object as? NSWindow else { return nil }
        let token = WindowToken(pid: getpid(), windowId: window.windowNumber)
        guard windows[token] === window,
              let entry = controller.workspaceManager.entry(for: token), entry.target.hostedMetadata != nil
        else { return nil }
        return RegisteredWindow(token: token, window: window, entry: entry)
    }

    private func isDirectFocusEvent(for window: NSWindow) -> Bool {
        guard let event = NSApp?.currentEvent, event.window === window else { return false }
        switch event.type {
        case .leftMouseDown,
             .rightMouseDown,
             .otherMouseDown,
             .keyDown:
            return true
        default:
            return false
        }
    }

    private func observeNativeGeometry(_ window: NSWindow, token: WindowToken) {
        guard controller.hasStartedServices, !applyingFrames.contains(token),
              let entry = controller.workspaceManager.entry(for: token), let role = entry.target.hostedMetadata?.role,
              !role.isSheet,
              controller.workspaceManager.hiddenState(for: token) == nil
        else { return }
        if let parent = role.parent {
            guard !applyingFrames.contains(parent) else { return }
            controller.workspaceManager.observeHostedWindowGeometry(frame: window.frame, for: token)
            return
        }
        controller.workspaceManager.observeHostedWindowGeometry(frame: window.frame, for: token)
        if entry.mode == .floating {
            controller.axEventHandler.updateFloatingWindowGeometryAndMonitorMembership(
                entry: entry,
                frame: window.frame
            )
            return
        }
        guard !window.inLiveResize, liveResizeStarts[token] == nil else { return }
        controller.layoutRefreshController.requestRelayout(
            reason: .axWindowChanged, affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    private func updateMinimized(_ minimized: Bool, notification: Notification) {
        guard let registered = registeredWindow(in: notification) else { return }
        let token = registered.token
        guard registered.entry.target.hostedMetadata?.role == .main else { return }
        if minimized {
            liveResizeStarts.removeValue(forKey: token)
            if let request = controller.intentLedger.activeManagedRequest, request.token != token,
               controller.workspaceManager.hostedFamilyRoot(for: request.token) == token
            {
                controller.cancelManagedFocusRequest(request)
            }
            for child in childTokens(of: token) { controller.intentLedger.discardPendingFocus(child) }
        }
        if controller.hasStartedServices {
            controller.axEventHandler.updateWindowMinimizedState(minimized, token: token, source: .service)
        } else {
            controller.workspaceManager.setWindowMinimized(minimized, token: token, source: .service)
        }
        _ = setFamilyHidden(minimized || controller.workspaceManager.hiddenState(for: token) != nil, requestedBy: token)
    }
}
