// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension StateReducer {
    struct ManagedFocusConfirmation {
        let token: WindowToken
        let workspaceId: WorkspaceDescriptor.ID
        let monitorId: Monitor.ID?
        let requestId: UInt64?
        let mode: TrackedWindowMode?
    }

    static func updatingFocusLease(
        in focusSession: FocusSessionSnapshot,
        lease: FocusPolicyLease?
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        focusSession.focusLease = lease
        return focusSession
    }

    static func managedFocusRequested(
        from focusSession: FocusSessionSnapshot,
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        requestId: UInt64
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        focusSession.pendingManagedFocus = PendingManagedFocusSnapshot(
            token: token,
            workspaceId: workspaceId,
            monitorId: monitorId,
            requestId: requestId
        )
        return focusSession
    }

    static func managedFocusConfirmed(
        from focusSession: FocusSessionSnapshot,
        target: ManagedFocusConfirmation
    ) -> FocusSessionSnapshot {
        let token = target.token
        let workspaceId = target.workspaceId
        let mode = target.mode
        let requestId = target.requestId
        let monitorId = target.monitorId
        if let requestId {
            guard focusSession.pendingManagedFocus.requestId == requestId,
                  focusSession.pendingManagedFocus.token == token,
                  focusSession.pendingManagedFocus.workspaceId == workspaceId
            else {
                return focusSession
            }
        } else if focusSession.pendingManagedFocus != .empty {
            guard focusSession.pendingManagedFocus.requestId == nil,
                  focusSession.pendingManagedFocus.token == token,
                  focusSession.pendingManagedFocus.workspaceId == workspaceId
            else {
                return focusSession
            }
        }
        return adoptingManagedFocus(
            in: focusSession,
            token: token,
            monitorId: monitorId,
            mode: mode
        )
    }

    static func adoptingManagedFocus(
        in focusSession: FocusSessionSnapshot,
        token: WindowToken,
        monitorId: Monitor.ID?,
        mode: TrackedWindowMode?
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        focusSession.selectedManagedToken = token
        focusSession.recordWindowFocus(token)
        focusSession.nativeFocusOwner = .managed(token)
        focusSession.pendingManagedFocus = .empty
        if mode != .floating {
            _ = focusSession.recordTiledFocus(token)
        }
        if focusSession.interactionMonitorId != monitorId {
            if let currentMonitorId = focusSession.interactionMonitorId,
               currentMonitorId != monitorId
            {
                focusSession.previousInteractionMonitorId = currentMonitorId
            }
            focusSession.interactionMonitorId = monitorId
        }
        if focusSession.suppressedFocusToken == token {
            focusSession.suppressedFocusToken = nil
        }
        return focusSession
    }

    static func managedFocusCancelled(
        from focusSession: FocusSessionSnapshot,
        token: WindowToken?,
        workspaceId: WorkspaceDescriptor.ID?,
        requestId: UInt64?
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        let matchesToken = token.map { focusSession.pendingManagedFocus.token == $0 } ?? true
        let matchesWorkspace = workspaceId.map { focusSession.pendingManagedFocus.workspaceId == $0 } ?? true
        let matchesRequest = requestId.map { focusSession.pendingManagedFocus.requestId == $0 }
            ?? (focusSession.pendingManagedFocus.requestId == nil)
        if matchesToken, matchesWorkspace, matchesRequest {
            focusSession.pendingManagedFocus = .empty
        }
        return focusSession
    }

    static func setFocusSession(
        _ next: FocusSessionSnapshot,
        current: FocusSessionSnapshot,
        plan: inout ActionPlan
    ) {
        guard next != current else { return }
        plan.focusSession = next
    }

    static func setViewport(
        _ next: ViewportState,
        for workspaceId: WorkspaceDescriptor.ID,
        currentSnapshot: ReconcileSnapshot,
        plan: inout ActionPlan
    ) {
        if let current = currentSnapshot.viewports[workspaceId], current == next {
            return
        }
        plan.viewport = .set(workspaceId: workspaceId, state: next)
    }

    static func rekeyedFocusSession(
        from focusSession: FocusSessionSnapshot,
        oldToken: WindowToken,
        newToken: WindowToken
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        if focusSession.selectedManagedToken == oldToken {
            focusSession.selectedManagedToken = newToken
        }
        if case .managed(oldToken) = focusSession.nativeFocusOwner {
            focusSession.nativeFocusOwner = .managed(newToken)
        }
        if focusSession.pendingManagedFocus.token == oldToken {
            focusSession.pendingManagedFocus.token = newToken
        }
        focusSession.replaceRememberedFocus(from: oldToken, to: newToken)
        if case let .external(identity) = focusSession.nativeFocusOwner {
            focusSession.nativeFocusOwner = .external(identity.rekeying(from: oldToken, to: newToken))
        }
        if focusSession.suppressedFocusToken == oldToken {
            focusSession.suppressedFocusToken = newToken
        }
        if focusSession.systemModalFocusToken == oldToken {
            focusSession.systemModalFocusToken = newToken
        }
        return focusSession
    }

    static func removingFocusState(
        from focusSession: FocusSessionSnapshot,
        token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID?
    ) -> FocusSessionSnapshot {
        var focusSession = focusSession
        if focusSession.selectedManagedToken == token {
            focusSession.selectedManagedToken = nil
        }
        if case .managed(token) = focusSession.nativeFocusOwner {
            focusSession.nativeFocusOwner = .none
        } else if case let .external(identity) = focusSession.nativeFocusOwner {
            focusSession.nativeFocusOwner = .external(identity.removingManagedToken(token))
        }
        if focusSession.pendingManagedFocus.token == token {
            focusSession.pendingManagedFocus = .empty
        }
        if focusSession.systemModalFocusToken == token {
            focusSession.systemModalFocusToken = nil
        }
        if focusSession.suppressedFocusToken == token {
            focusSession.suppressedFocusToken = nil
        }
        focusSession.clearRememberedFocus(token, workspaceId: workspaceId)
        return focusSession
    }

    static func reassigningFocusState(
        from focusSession: FocusSessionSnapshot,
        token: WindowToken,
        sourceWorkspaceId: WorkspaceDescriptor.ID?,
        workspaceId: WorkspaceDescriptor.ID
    ) -> FocusSessionSnapshot? {
        var focusSession = focusSession
        var changed = false

        if let sourceWorkspaceId, sourceWorkspaceId != workspaceId {
            if focusSession.lastTiledFocusedByWorkspace[sourceWorkspaceId] == token {
                focusSession.lastTiledFocusedByWorkspace.removeValue(forKey: sourceWorkspaceId)
                changed = true
            }
            if focusSession.lastFloatingFocusedByWorkspace[sourceWorkspaceId] == token {
                focusSession.lastFloatingFocusedByWorkspace.removeValue(forKey: sourceWorkspaceId)
                changed = true
            }
            if focusSession.lastFocusedByWorkspace[sourceWorkspaceId] == token {
                focusSession.lastFocusedByWorkspace.removeValue(forKey: sourceWorkspaceId)
                changed = true
            }
        }

        if focusSession.pendingManagedFocus.token == token,
           let pendingWorkspaceId = focusSession.pendingManagedFocus.workspaceId,
           pendingWorkspaceId != workspaceId
        {
            changed = focusSession.clearPendingManagedFocus() || changed
        }

        return changed ? focusSession : nil
    }
}
