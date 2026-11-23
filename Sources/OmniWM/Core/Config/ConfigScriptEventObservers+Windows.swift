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

struct WindowMembershipBatch {
    typealias Record = (depth: Int, change: WindowModel.MembershipChange)
    private var storage: [Record] = []
    private let start: Int

    init(taking pending: inout [Record], depth: Int) {
        swap(&storage, &pending)
        var first = storage.count
        while first > 0, storage[first - 1].depth == depth { first -= 1 }
        start = first
        if first > 0 { pending.append(contentsOf: storage[..<first]) }
    }

    var records: ArraySlice<Record> {
        storage[start...]
    }

    mutating func recycle(into pending: inout [Record]) {
        guard pending.isEmpty else { return }
        storage.removeAll(keepingCapacity: true)
        swap(&pending, &storage)
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

    private struct WindowIdentity {
        let token: WindowToken
        let workspace: WorkspaceDescriptor.ID
        let bundleId: String?

        init(_ entry: borrowing WindowState) {
            token = entry.token
            workspace = entry.workspaceId
            if let appId = entry.target.hostedMetadata?.appId {
                bundleId = appId
            } else {
                bundleId = entry.managedReplacementMetadata?.bundleId
            }
        }
    }

    func windowOpened(_ token: WindowToken) {
        guard let controller,
              let identity = controller.workspaceManager.withEntry(token, WindowIdentity.init) else { return }
        emitWindow(.windowOpen, identity: identity, workspace: identity.workspace, controller: controller)
    }

    func windowClosed(_ entry: borrowing WindowState) {
        guard let controller else { return }
        emitWindow(.windowClose, identity: WindowIdentity(entry), workspace: entry.workspaceId, controller: controller)
    }

    func publishWindowMoves(
        _ moves: borrowing WindowMembershipBatch,
        transaction txn: borrowing ReconcileTxn,
        wasTracked: Bool
    ) {
        let firstAdmission: WindowToken? = if !wasTracked,
                                              case .windowAdmitted = txn.event { txn.event.token } else { nil }
        let hydratedToken = txn.plan.persistedHydration != nil ? txn.event.token : nil
        var sentHydration = false
        for record in moves.records {
            let change = record.change
            if change.token == firstAdmission { continue }
            if change.token == hydratedToken {
                guard !sentHydration,
                      let workspace = controller?.workspaceManager.workspace(for: change.token) else { continue }
                sentHydration = true
                if change.source != workspace {
                    windowMoved(.init(token: change.token, source: change.source, destination: workspace))
                }
            } else {
                windowMoved(change)
            }
        }
    }

    private func windowMoved(_ change: WindowModel.MembershipChange) {
        guard let controller,
              let identity = controller.workspaceManager.withEntry(change.token, WindowIdentity.init) else { return }
        emitWindow(
            .windowMoveToWorkspace, identity: identity, workspace: change.destination,
            previous: change.source, controller: controller
        )
    }

    private func emitWindow(
        _ kind: ConfigScriptEventKind, identity: WindowIdentity, workspace: WorkspaceDescriptor.ID,
        previous: WorkspaceDescriptor.ID? = nil, controller: WMController
    ) {
        let manager = controller.workspaceManager
        let bundleId = identity.bundleId ?? controller.appInfoCache.cachedBundleId(for: identity.token.pid)
        emit(kind, .init(
            id: IPCWindowOpaqueID.encode(token: identity.token, sessionToken: controller.automationSessionToken),
            bundleId: bundleId,
            edge: .workspace(
                id: workspace.uuidString, name: manager.descriptor(for: workspace)?.name,
                previousId: previous?.uuidString, previousName: previous.flatMap { manager.descriptor(for: $0)?.name }
            )
        ))
    }
}
