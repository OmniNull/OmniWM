// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension WindowToken {
    @MainActor
    init(ownWindow window: NSWindow) {
        self.init(pid: getpid(), windowId: window.windowNumber)
    }
}

@MainActor
final class ShellAppWindowManager: NSObject, NSWindowDelegate {
    nonisolated static let exampleID = "example"

    unowned let controller: WMController
    var windows: [WindowToken: NSWindow] = [:]
    var runtimes: [UUID: ShellAppRuntime] = [:]
    var liveResizeStarts: [WindowToken: CGRect] = [:]
    var applyingFrames: Set<WindowToken> = []
    var closeGuards: [WindowToken: () -> Bool] = [:]
    var pendingSettingsWindow: PendingSettingsWindow?
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
        guard windows[token] != nil else { return false }
        if controller.workspaceManager.entry(for: token)?.target.hostedMetadata?.role.parent != nil { return true }
        return applyFrame(frame, to: token, components: components)
    }

    @discardableResult
    func setFloatingFrame(_ frame: CGRect, for token: WindowToken) -> Bool {
        guard controller.workspaceManager.entry(for: token)?.target.hostedMetadata?.role.isSheet == false else {
            return false
        }
        guard applyFrame(frame, to: token, components: .all) else { return false }
        if case .utility = controller.workspaceManager.entry(for: token)?.target.hostedMetadata?.role,
           let window = windows[token]
        {
            controller.workspaceManager.observeHostedWindowGeometry(frame: window.frame, for: token)
        }
        return true
    }

    @discardableResult
    func applyFrame(_ frame: CGRect, to token: WindowToken, components: AXFrameComponents) -> Bool {
        guard let window = windows[token] else { return false }
        var target = window.frame
        if components.contains(.position) {
            target.origin = CGPoint(x: frame.minX, y: frame.maxY - target.height)
        }
        if components.contains(.size) {
            let top = target.maxY
            target.size = frame.size
            if case .utility = controller.workspaceManager.entry(for: token)?.target.hostedMetadata?.role {
                let minimum = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
                target.size.width = max(target.width, minimum.width)
                target.size.height = max(target.height, minimum.height)
            }
            target.origin.y = top - target.height
        }
        if window.frame != target {
            applyingFrames.insert(token)
            defer { applyingFrames.remove(token) }
            window.setFrame(target, display: true)
        }
        resizeContent(of: token, window: window)
        return true
    }

    @discardableResult
    func setHidden(_ hidden: Bool, for token: WindowToken) -> Bool {
        setFamilyHidden(hidden, requestedBy: token)
    }

    @discardableResult
    func orderFront(_ token: WindowToken) -> Bool {
        guard let window = windows[token] else { return false }
        if let parent = controller.workspaceManager.entry(for: token)?.target.hostedMetadata?.role.parent {
            _ = setHidden(false, for: parent)
        }
        window.orderFront(nil)
        setContentVisible(!window.isMiniaturized, token: token)
        return true
    }

    @discardableResult
    func focus(_ token: WindowToken, raisesWindow: Bool = true) -> Bool {
        let token = activeSheet(for: token) ?? token
        guard let window = windows[token], controller.workspaceManager.entry(for: token) != nil else { return false }
        guard restoreFamilyIfMinimized(for: token) else { return false }
        if let parent = controller.workspaceManager.entry(for: token)?.target.hostedMetadata?.role.parent {
            _ = setHidden(false, for: parent)
        }
        if raisesWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.makeKey()
            focusWithoutRaising(token)
        }
        setContentVisible(true, token: token)
        if raisesWindow {
            activateApplication()
            focusWithoutRaising(token)
        }
        return true
    }

    @discardableResult
    func close(_ token: WindowToken) -> Bool {
        guard let window = windows[token] else { return false }
        if controller.workspaceManager.entry(for: token)?.target.hostedMetadata?.role == .main,
           let sheet = activeSheet(for: token)
        { closeChild(sheet)
            return true
        }
        if controller.workspaceManager.entry(for: token)?.target.hostedMetadata?.role.parent != nil {
            closeChild(token)
            return true
        }
        window.performClose(nil)
        return true
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        controller.shellAppCatalog.stopObserving()
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
        closeGuards.removeValue(forKey: token)
        if let parent = window.sheetParent { parent.endSheet(window, returnCode: .cancel) }
        window.parent?.removeChildWindow(window)
        if let metadata = controller.workspaceManager.entry(for: token)?.target.hostedMetadata {
            if metadata.role == .main {
                for child in childTokens(of: token) { closeChild(child, recoverFocus: false) }
                runtimes.removeValue(forKey: metadata.instanceID)?.close()
                publishApprovals()
            } else {
                runtimes[metadata.instanceID]?.removeRoot(metadata.rootID)
            }
        }
        applyingFrames.remove(token)
        liveResizeStarts.removeValue(forKey: token)
        guard let entry = controller.workspaceManager.entry(for: token),
              entry.target.hostedMetadata != nil else { return }
        guard controller.hasStartedServices, !isShuttingDown, entry.target.hostedMetadata?.role == .main else {
            controller.workspaceManager.removeHostedWindow(token)
            return
        }
        controller.axEventHandler.retireManagedWindow(
            entry, reason: .destroyed(shouldRecoverFocus: true, allowsPreferredRecoveryToken: true)
        )
    }
}
