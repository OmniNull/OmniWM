// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellAppWindowManager {
    @discardableResult
    func open(_ appID: String, bundle: Bundle = .module, newInstance: Bool = false) -> Bool {
        let definition = appID == Self.exampleID
            ? ShellAppDefinition.example(in: bundle) : controller.shellAppCatalog.definitions[appID]
        guard let definition,
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
        guard !isShuttingDown else { return false }
        if !newInstance, let token = existingWindow(for: definition.id) {
            return navigateToHostedWindow(token)
        }
        let window = makeWindow(definition)
        let session = ShellAppRuntime(
            definition: definition, window: window, resources: ShellResources(motion: controller.motionPolicy),
            permissions: controller.workspaceBarManager.shellPermissions
        )
        let minimum = window.frameRect(forContentRect: CGRect(origin: .zero, size: definition.minimumContentSize)).size
        guard let token = admit(
            window, metadata: HostedWindowMetadata(
                appId: definition.id, title: definition.title, minimumSize: minimum, icon: definition.icon,
                instanceID: session.id, rootID: session.id
            ),
            to: workspace
        ) else { session.close()
            window.close()
            return false
        }
        runtimes[session.id] = session
        session.onApprovalsChange = { [weak self] in self?.publishApprovals() }
        session.onWindowRequest = { [weak self, weak session] request in
            guard let self, let session, runtimes[session.id] === session else {
                return "The owning app instance is no longer available."
            }
            return handleWindowRequest(request, runtime: session, parent: token)
        }
        session.start()
        focusAdmittedWindow(token, in: workspace)
        return true
    }

    @discardableResult
    func navigateToHostedWindow(_ token: WindowToken) -> Bool {
        if windows[token]?.isMiniaturized == true { windows[token]?.deminiaturize(nil) }
        guard let handle = controller.workspaceManager.handle(for: token) else { return false }
        return controller.windowActionHandler.navigateToWindow(handle: handle)
    }

    func focusAdmittedWindow(_ token: WindowToken, in workspace: WorkspaceDescriptor.ID) {
        controller.layoutRefreshController.requestRelayout(reason: .axWindowChanged, affectedWorkspaceIds: [workspace])
        _ = controller.focusWindow(token)
    }

    private func existingWindow(for appID: String) -> WindowToken? {
        let candidates = Set(windows.keys.filter { token in
            guard let metadata = controller.workspaceManager.entry(for: token)?.target.hostedMetadata,
                  metadata.role == .main, metadata.appId == appID,
                  let runtime = runtimes[metadata.instanceID], !runtime.closed else { return false }
            return true
        })
        return controller.workspaceManager.windowFocusRecencyOrder.first(where: candidates.contains)
            ?? candidates.min { $0.windowId < $1.windowId }
    }

    static func makeWindow(_ definition: ShellAppDefinition) -> NSWindow {
        let window = ShellAppNativeWindow(
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
