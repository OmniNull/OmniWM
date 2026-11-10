// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellAppWindowManager {
    func runtime(for token: WindowToken) -> ShellAppRuntime? {
        guard let metadata = controller.workspaceManager.entry(for: token)?.target.hostedMetadata else { return nil }
        return runtimes[metadata.instanceID]
    }

    func slot(for token: WindowToken) -> ShellAppRuntime.Slot? {
        guard let metadata = controller.workspaceManager.entry(for: token)?.target.hostedMetadata else { return nil }
        return runtimes[metadata.instanceID]?.slots[metadata.rootID]
    }

    func resizeContent(of token: WindowToken, window: NSWindow) {
        guard let metadata = controller.workspaceManager.entry(for: token)?.target.hostedMetadata else { return }
        runtimes[metadata.instanceID]?.resize(contentSize(of: window), rootID: metadata.rootID)
    }

    func setContentVisible(_ visible: Bool, token: WindowToken) {
        guard let metadata = controller.workspaceManager.entry(for: token)?.target.hostedMetadata else { return }
        let visible = metadata.role.parent.map { parent in
            visible && windows[parent]?.isMiniaturized == false
                && controller.workspaceManager.hiddenState(for: parent) == nil
        } ?? visible
        runtimes[metadata.instanceID]?.setVisible(visible, rootID: metadata.rootID)
    }

    func childTokens(of parent: WindowToken) -> [WindowToken] {
        Array(controller.workspaceManager.hostedFamilyTokens(for: parent).dropFirst())
    }

    func activeSheet(for token: WindowToken) -> WindowToken? {
        let parent = controller.workspaceManager.entry(for: token)?.target.hostedMetadata?.role.parent ?? token
        return childTokens(of: parent).first {
            controller.workspaceManager.entry(for: $0)?.target.hostedMetadata?.role.isSheet == true
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let token = WindowToken(pid: getpid(), windowId: sender.windowNumber)
        if controller.workspaceManager.entry(for: token)?.target.hostedMetadata?.role == .main,
           let child = activeSheet(for: token)
        {
            closeChild(child)
            return false
        }
        if controller.workspaceManager.entry(for: token)?.target.hostedMetadata?.role.parent != nil {
            closeChild(token)
            return false
        }
        return closeGuards[token]?() ?? true
    }

    func handleWindowRequest(_ request: ShellWindowRequest, runtime: ShellAppRuntime, parent: WindowToken) -> String? {
        guard !isShuttingDown, !runtime.closed, runtime.slots[request.rootID] != nil,
              let declaration = runtime.definition.children[request.childID]
        else {
            return "The child window is not declared by this app."
        }
        switch request.operation {
        case .open:
            switch declaration.kind {
            case .sheet: return openSheet(declaration, runtime: runtime, parent: parent)
            case .utility: return openUtility(declaration, runtime: runtime, parent: parent)
            }
        case .close:
            guard let token = childTokens(of: parent).first(where: {
                controller.workspaceManager.entry(for: $0)?.target.hostedMetadata?.role.declarationID == declaration.id
            }) else { return "The child window is not open." }
            closeChild(token)
            return nil
        }
    }

    func openSheet(_ declaration: ShellAppChildDefinition, runtime: ShellAppRuntime, parent: WindowToken) -> String? {
        guard let parentWindow = availableParent(parent, runtime: runtime) else {
            return "The parent window is unavailable."
        }
        guard activeSheet(for: parent) == nil, parentWindow.attachedSheet == nil else {
            return "This window already has an active sheet."
        }
        guard let (token, window) = createChild(declaration, runtime: runtime, parent: parent) else {
            return "The sheet could not be admitted."
        }
        slot(for: token)?.surface.onUnhandledEscape = { [weak self] in self?.closeChild(token) }
        parentWindow.beginSheet(window) { [weak self, weak window] _ in
            guard let self, let window, windows[token] === window else { return }
            closeChild(token)
        }
        _ = controller.focusWindow(token)
        return nil
    }

    func closeChild(_ token: WindowToken, recoverFocus: Bool = true) {
        guard let window = windows[token],
              let metadata = controller.workspaceManager.entry(for: token)?.target.hostedMetadata,
              let parent = metadata.role.parent else { return }
        if let sheetParent = window.sheetParent { sheetParent.endSheet(window, returnCode: .cancel) }
        guard windows[token] === window else { return }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        window.close()
        if recoverFocus, !isShuttingDown, windows[parent] != nil { _ = controller.focusWindow(parent) }
    }
}
