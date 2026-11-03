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
        runtimes[metadata.instanceID]?.setVisible(visible, rootID: metadata.rootID)
    }

    func childTokens(of parent: WindowToken) -> [WindowToken] {
        controller.workspaceManager.allEntries().compactMap { entry in
            entry.target.hostedMetadata?.role.parent == parent ? entry.token : nil
        }
    }

    func activeSheet(for token: WindowToken) -> WindowToken? {
        let parent = controller.workspaceManager.entry(for: token)?.target.hostedMetadata?.role.parent ?? token
        return childTokens(of: parent).first
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let token = WindowToken(pid: getpid(), windowId: sender.windowNumber)
        if let child = activeSheet(for: token), child != token {
            closeSheet(child)
            return false
        }
        if controller.workspaceManager.entry(for: token)?.target.hostedMetadata?.role.parent != nil {
            closeSheet(token)
            return false
        }
        return true
    }

    func handleWindowRequest(_ request: ShellWindowRequest, runtime: ShellAppRuntime, parent: WindowToken) -> String? {
        guard !isShuttingDown, !runtime.closed, runtime.slots[request.rootID] != nil,
              let declaration = runtime.definition.children[request.childID]
        else {
            return "The child window is not declared by this app."
        }
        switch request.operation {
        case .open:
            return openSheet(declaration, runtime: runtime, parent: parent)
        case .close:
            guard let token = childTokens(of: parent).first(where: {
                controller.workspaceManager.entry(for: $0)?.target.hostedMetadata?.role
                    == .sheet(parent: parent, declarationID: declaration.id)
            }) else { return "The child window is not open." }
            closeSheet(token)
            return nil
        }
    }

    func openSheet(_ declaration: ShellAppChildDefinition, runtime: ShellAppRuntime, parent: WindowToken) -> String? {
        guard let parentWindow = windows[parent], parentWindow.isVisible, !parentWindow.isMiniaturized,
              let parentEntry = controller.workspaceManager.entry(for: parent),
              parentEntry.target.hostedMetadata?.instanceID == runtime.id,
              controller.workspaceManager.hiddenState(for: parent) == nil
        else {
            return "The parent window is unavailable."
        }
        guard activeSheet(for: parent) == nil, parentWindow.attachedSheet == nil else {
            return "This window already has an active sheet."
        }
        let definition = ShellAppDefinition(
            id: runtime.definition.id, title: declaration.title, contentSize: declaration.contentSize,
            minimumContentSize: declaration.minimumContentSize, folder: runtime.definition.folder,
            icon: runtime.definition.icon
        )
        let window = makeWindow(definition)
        window.styleMask.remove([.miniaturizable, .resizable])
        window.collectionBehavior.insert(.fullScreenNone)
        window.animationBehavior = .none
        let rootID = UUID()
        let metadata = HostedWindowMetadata(
            appId: definition.id, title: declaration.title,
            minimumSize: window.frameRect(forContentRect: CGRect(origin: .zero, size: declaration.minimumContentSize))
                .size,
            icon: definition.icon, instanceID: runtime.id, rootID: rootID,
            role: .sheet(parent: parent, declarationID: declaration.id)
        )
        guard let token = admit(window, metadata: metadata, to: parentEntry.workspaceId) else {
            window.close()
            return "The sheet could not be admitted."
        }
        runtime.addRoot(
            id: rootID, viewName: declaration.view, window: window,
            resources: ShellResources(motion: controller.motionPolicy)
        )
        runtime.slots[rootID]?.surface.onUnhandledEscape = { [weak self] in self?.closeSheet(token) }
        window.makeFirstResponder(runtime.slots[rootID]?.surface.view)
        parentWindow.beginSheet(window) { [weak self, weak window] _ in
            guard let self, let window, windows[token] === window else { return }
            closeSheet(token)
        }
        _ = controller.focusWindow(token)
        return nil
    }

    func closeSheet(_ token: WindowToken) {
        guard let window = windows[token],
              let metadata = controller.workspaceManager.entry(for: token)?.target.hostedMetadata,
              let parent = metadata.role.parent else { return }
        if let sheetParent = window.sheetParent { sheetParent.endSheet(window, returnCode: .cancel) }
        window.orderOut(nil)
        window.close()
        if !isShuttingDown, windows[parent] != nil { _ = controller.focusWindow(parent) }
    }
}
