// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class ShellAppWindowManager: NSObject, NSWindowDelegate {
    nonisolated static let exampleID = "example"

    unowned let controller: WMController
    var windows: [WindowToken: NSWindow] = [:]
    var sessions: [WindowToken: ShellAppWindowSession] = [:]
    var liveResizeStarts: [WindowToken: CGRect] = [:]
    var applyingFrames: Set<WindowToken> = []
    private(set) var isShuttingDown = false
    var makeWindow: @MainActor (ShellAppDefinition) -> NSWindow = ShellAppWindowManager.makeWindow
    var activateApplication: () -> Void = { NSApp.activate() }
    var focusWithoutRaising: (WindowToken) -> Void = { token in
        WindowFocusDispatcher.shared.drain()
        MainThreadAXSpanTrace.measure(.privateFocus, pid: token.pid, windowId: token.windowId) {
            OmniWM.focusWindow(pid: token.pid, windowId: UInt32(token.windowId))
        }
    }

    init(controller: WMController) {
        self.controller = controller
    }

    @discardableResult
    func admit(
        _ window: NSWindow,
        metadata: HostedWindowMetadata,
        to workspaceId: WorkspaceDescriptor.ID
    ) -> WindowToken? {
        let token = WindowToken(pid: getpid(), windowId: window.windowNumber)
        guard !isShuttingDown, windows[token] == nil else { return nil }
        windows[token] = window
        guard controller.workspaceManager.addHostedWindow(
            token: token, metadata: metadata, to: workspaceId, initialFrame: window.frame
        ) != nil else {
            windows.removeValue(forKey: token)
            return nil
        }
        window.delegate = self
        return token
    }

    func frame(for token: WindowToken) -> CGRect? {
        windows[token]?.frame
    }

    @discardableResult
    func setFrame(_ frame: CGRect, for token: WindowToken, components: AXFrameComponents = .all) -> Bool {
        guard let window = windows[token] else { return false }
        var target = window.frame
        if components.contains(.position) {
            target.origin = CGPoint(x: frame.minX, y: frame.maxY - target.height)
        }
        if components.contains(.size) {
            let top = target.maxY
            target.size = frame.size
            target.origin.y = top - target.height
        }
        if window.frame != target {
            applyingFrames.insert(token)
            defer { applyingFrames.remove(token) }
            window.setFrame(target, display: true)
        }
        sessions[token]?.resize(contentSize(of: window))
        return true
    }

    @discardableResult
    func setHidden(_ hidden: Bool, for token: WindowToken) -> Bool {
        guard let window = windows[token] else { return false }
        if hidden, window.isVisible {
            window.orderOut(nil)
        } else if !hidden, !window.isVisible {
            window.orderFront(nil)
        }
        sessions[token]?.setVisible(!hidden && !window.isMiniaturized)
        return true
    }

    @discardableResult
    func orderFront(_ token: WindowToken) -> Bool {
        guard let window = windows[token] else { return false }
        window.orderFront(nil)
        sessions[token]?.setVisible(!window.isMiniaturized)
        return true
    }

    @discardableResult
    func focus(_ token: WindowToken, raisesWindow: Bool = true) -> Bool {
        guard let window = windows[token], controller.workspaceManager.entry(for: token) != nil else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if raisesWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.makeKey()
            focusWithoutRaising(token)
        }
        sessions[token]?.setVisible(true)
        if raisesWindow { activateApplication() }
        return true
    }

    @discardableResult
    func close(_ token: WindowToken) -> Bool {
        guard let window = windows[token] else { return false }
        window.performClose(nil)
        return true
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        controller.layoutRefreshController.workspaceSwipe.cancelAll(reason: "quit")
        if let request = controller.intentLedger.activeManagedRequest, windows[request.token] != nil {
            controller.cancelManagedFocusRequest(request)
        }
        for window in Array(windows.values) { window.close() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let token = windows.first(where: { $0.value === window })?.key
        else { return }
        windows.removeValue(forKey: token)
        sessions.removeValue(forKey: token)?.close()
        applyingFrames.remove(token)
        liveResizeStarts.removeValue(forKey: token)
        guard let entry = controller.workspaceManager.entry(for: token),
              entry.target.hostedMetadata != nil else { return }
        guard controller.hasStartedServices, !isShuttingDown else {
            controller.workspaceManager.removeHostedWindow(token)
            return
        }
        controller.axEventHandler.retireManagedWindow(
            entry, reason: .destroyed(shouldRecoverFocus: true, allowsPreferredRecoveryToken: true)
        )
    }
}
