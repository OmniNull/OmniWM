// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellAppWindowManager {
    @discardableResult
    func open(_ appID: String, bundle: Bundle = .module) -> Bool {
        guard appID == Self.exampleID, let definition = ShellAppDefinition.example(in: bundle),
              let workspace = controller.activeWorkspace() else { return false }
        return open(definition, in: workspace.id)
    }

    @discardableResult
    func open(_ definition: ShellAppDefinition, in workspace: WorkspaceDescriptor.ID) -> Bool {
        if let token = sessions.first(where: { $0.value.definition.id == definition.id && !$0.value.closed })?.key {
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
