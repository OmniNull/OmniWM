// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension WindowModel {
    struct MembershipChange {
        let token: WindowToken
        let source: WorkspaceDescriptor.ID
        let destination: WorkspaceDescriptor.ID
    }
}

extension ConfigScriptEventObservers {
    func installWindowEdges(on controller: WMController, kinds: Set<ConfigScriptEventKind>) {
        let manager = controller.workspaceManager
        if kinds.contains(.windowOpen) { manager.scriptWindowOpenObserver = self }
        if kinds.contains(.windowClose) { manager.scriptWindowCloseObserver = self }
        if kinds.contains(.windowMoveToWorkspace) { manager.scriptWindowMoveObserver = self }
    }

    func detachWindowEdges(from controller: WMController) {
        let manager = controller.workspaceManager
        if manager.scriptWindowOpenObserver === self { manager.scriptWindowOpenObserver = nil }
        if manager.scriptWindowCloseObserver === self { manager.scriptWindowCloseObserver = nil }
        if manager.scriptWindowMoveObserver === self { manager.scriptWindowMoveObserver = nil }
    }

    func windowOpened(_ token: WindowToken, in manager: WorkspaceManager) {
        guard var identity = manager.configWindow(for: token) else { return }
        emitWindow(
            .windowOpen,
            token: identity.token, bundle: identity.takeBundle(),
            edge: .workspace(id: identity.workspace, name: manager.workspaceCatalog.name(for: identity.workspace)),
            in: manager
        )
    }

    func windowMoved(_ change: WindowModel.MembershipChange, previousName: String?, in manager: WorkspaceManager) {
        guard var identity = manager.configWindow(for: change.token) else { return }
        emitWindow(
            .windowMoveToWorkspace, token: identity.token, bundle: identity.takeBundle(),
            edge: .workspace(
                id: change.destination, name: manager.workspaceCatalog.name(for: change.destination),
                previousId: change.source, previousName: previousName
            ),
            in: manager
        )
    }

    fileprivate func emitWindow(
        _ kind: ConfigScriptEventKind, token: WindowToken, bundle: consuming String?,
        edge: consuming ConfigScriptNativeEvent.Edge, in manager: WorkspaceManager
    ) {
        var bundleId = consume bundle
        if bundleId == nil { bundleId = nativeInput.cachedBundleID(for: token.pid) }
        publishNative(kind, .init(
            id: hasSynchronousDelivery ? .window(token, nativeInput.session.identity, nativeInput.session.epoch)
                : .capturedWindow(token, nativeInput.session.epoch),
            bundleId: consume bundleId,
            edge: consume edge
        ), in: manager)
    }
}

struct ConfigScriptWindowIdentity {
    let token: WindowToken
    let workspace: WorkspaceDescriptor.ID
    private var bundle: String?

    mutating func takeBundle() -> String? {
        var result: String? = ""
        swap(&result, &bundle)
        return result
    }

    init(_ row: borrowing WindowState) {
        token = row.token
        workspace = row.workspaceId
        switch row.target {
        case let .hosted(metadata): bundle = metadata.appId
        case .external: bundle = row.managedReplacementMetadata?.bundleId
        }
    }
}

extension WorkspaceManager {
    func publishOpenedWindow(_ token: WindowToken) {
        func publish(_ observer: ConfigScriptEventObservers) {
            observer.windowOpened(token, in: self)
        }
        if let client = ConfigScriptEventObservers.borrowRegistration(&scriptWindowOpenObserver, publish) {
            publish(client)
        }
    }

    func publishClosedWindow(_ identity: consuming ConfigScriptWindowIdentity, name: String?) {
        func publish(_ observer: ConfigScriptEventObservers) {
            observer.emitWindow(
                .windowClose,
                token: identity.token,
                bundle: identity.takeBundle(),
                edge: .workspace(id: identity.workspace, name: name),
                in: self
            )
        }
        if let client = ConfigScriptEventObservers.borrowRegistration(&scriptWindowCloseObserver, publish) {
            publish(client)
        }
    }
}
