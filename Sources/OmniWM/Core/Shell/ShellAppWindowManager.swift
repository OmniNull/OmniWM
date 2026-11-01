// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class ShellAppWindowManager: NSObject, NSWindowDelegate {
    private unowned let controller: WMController
    private var windows: [WindowToken: NSWindow] = [:]
    var activateApplication: () -> Void = { NSApp.activate() }

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
        guard windows[token] == nil else { return nil }
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
        if window.frame != target { window.setFrame(target, display: true) }
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
        return true
    }

    @discardableResult
    func orderFront(_ token: WindowToken) -> Bool {
        guard let window = windows[token] else { return false }
        window.orderFront(nil)
        return true
    }

    @discardableResult
    func focus(_ token: WindowToken) -> Bool {
        guard let window = windows[token], controller.workspaceManager.entry(for: token) != nil else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        activateApplication()
        return true
    }

    @discardableResult
    func close(_ token: WindowToken) -> Bool {
        guard let window = windows[token] else { return false }
        window.performClose(nil)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let token = windows.first(where: { $0.value === window })?.key
        else { return }
        windows.removeValue(forKey: token)
        guard let entry = controller.workspaceManager.entry(for: token),
              entry.target.hostedMetadata != nil else { return }
        controller.axEventHandler.retireManagedWindow(
            entry, reason: .destroyed(shouldRecoverFocus: true, allowsPreferredRecoveryToken: true)
        )
    }
}
