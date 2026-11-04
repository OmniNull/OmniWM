// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellAppWindowManager {
    func availableParent(_ parent: WindowToken, runtime: ShellAppRuntime) -> NSWindow? {
        guard let window = windows[parent], window.isVisible, !window.isMiniaturized,
              let entry = controller.workspaceManager.entry(for: parent),
              entry.target.hostedMetadata?.role == .main,
              entry.target.hostedMetadata?.instanceID == runtime.id,
              controller.workspaceManager.hiddenState(for: parent) == nil else { return nil }
        return window
    }

    func createChild(
        _ declaration: ShellAppChildDefinition, runtime: ShellAppRuntime, parent: WindowToken
    ) -> (WindowToken, NSWindow)? {
        guard let entry = controller.workspaceManager.entry(for: parent), let parentWindow = windows[parent]
        else { return nil }
        let definition = ShellAppDefinition(
            id: runtime.definition.id, title: declaration.title, contentSize: declaration.contentSize,
            minimumContentSize: declaration.minimumContentSize, folder: runtime.definition.folder,
            icon: runtime.definition.icon
        )
        let window = makeWindow(definition)
        window.level = .normal
        window.styleMask.remove(.miniaturizable)
        window.collectionBehavior.insert(.fullScreenNone)
        window.animationBehavior = .none
        let role: HostedWindowRole
        switch declaration.kind {
        case .sheet:
            window.styleMask.remove(.resizable)
            role = .sheet(parent: parent, declarationID: declaration.id)
        case .utility:
            role = .utility(parent: parent, declarationID: declaration.id)
            var frame = window.frame
            frame.origin = CGPoint(x: parentWindow.frame.maxX, y: parentWindow.frame.maxY - frame.height)
            if let monitor = controller.workspaceManager.monitor(for: entry.workspaceId) {
                frame = FloatingFrameGeometry.clamped(frame, in: monitor.visibleFrame)
            }
            window.setFrame(frame, display: false)
        }
        let rootID = UUID()
        let metadata = HostedWindowMetadata(
            appId: definition.id, title: declaration.title,
            minimumSize: window.frameRect(forContentRect: CGRect(origin: .zero, size: declaration.minimumContentSize))
                .size,
            icon: definition.icon, instanceID: runtime.id, rootID: rootID, role: role
        )
        guard let token = admit(window, metadata: metadata, to: entry.workspaceId) else {
            window.close()
            return nil
        }
        runtime.addRoot(
            id: rootID, viewName: declaration.view, window: window,
            resources: ShellResources(motion: controller.motionPolicy)
        )
        window.makeFirstResponder(runtime.slots[rootID]?.surface.view)
        return (token, window)
    }

    func openUtility(_ declaration: ShellAppChildDefinition, runtime: ShellAppRuntime, parent: WindowToken) -> String? {
        guard let parentWindow = availableParent(parent, runtime: runtime) else {
            return "The parent window is unavailable."
        }
        if let existing = childTokens(of: parent).first(where: {
            controller.workspaceManager.entry(for: $0)?.target.hostedMetadata?.role.declarationID == declaration.id
        }) {
            _ = controller.focusWindow(existing)
            return nil
        }
        guard let (token, window) = createChild(declaration, runtime: runtime, parent: parent) else {
            return "The utility window could not be admitted."
        }
        parentWindow.addChildWindow(window, ordered: .above)
        _ = controller.focusWindow(token)
        return nil
    }
}
