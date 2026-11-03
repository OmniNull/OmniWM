// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellAppWindowManager {
    @discardableResult
    func open(_ appID: String, bundle: Bundle = .module, newInstance: Bool = false) -> Bool {
        guard appID == Self.exampleID, let definition = ShellAppDefinition.example(in: bundle),
              let workspace = controller.activeWorkspace() else { return false }
        return open(definition, in: workspace.id, newInstance: newInstance)
    }

    @discardableResult
    func newWindow(_ appID: String, bundle: Bundle = .module) -> Bool {
        open(appID, bundle: bundle, newInstance: true)
    }

    @discardableResult
    func open(
        _ definition: ShellAppDefinition,
        in workspace: WorkspaceDescriptor.ID,
        newInstance: Bool = false
    ) -> Bool {
        if !newInstance, let token = existingWindow(for: definition.id) {
            if windows[token]?.isMiniaturized == true { windows[token]?.deminiaturize(nil) }
            guard let handle = controller.workspaceManager.handle(for: token) else { return false }
            return controller.windowActionHandler.navigateToWindow(handle: handle)
        }
        let window = makeWindow(definition)
        let session = ShellAppWindowSession(
            definition: definition, window: window, resources: ShellResources(motion: controller.motionPolicy)
        )
        let minimum = window.frameRect(forContentRect: CGRect(origin: .zero, size: definition.minimumContentSize)).size
        guard let token = admit(
            window, metadata: HostedWindowMetadata(appId: definition.id, title: definition.title, minimumSize: minimum),
            to: workspace
        ) else { session.close()
            window.close()
            return false
        }
        sessions[token] = session
        session.start()
        controller.layoutRefreshController.requestRelayout(reason: .axWindowChanged, affectedWorkspaceIds: [workspace])
        _ = controller.focusWindow(token)
        return true
    }

    private func existingWindow(for appID: String) -> WindowToken? {
        let candidates = Set(sessions.compactMap { token, session -> WindowToken? in
            guard !session.closed, session.definition.id == appID, windows[token] != nil,
                  controller.workspaceManager.entry(for: token)?.target.hostedMetadata?.appId == appID
            else { return nil }
            return token
        })
        return controller.workspaceManager.windowFocusRecencyOrder.first(where: candidates.contains)
            ?? candidates.min { $0.windowId < $1.windowId }
    }

    static func makeWindow(_ definition: ShellAppDefinition) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: definition.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = definition.title
        window.contentMinSize = definition.minimumContentSize
        window.animationBehavior = .none
        window.center()
        return window
    }
}
