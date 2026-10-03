// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension StateReducer {
    static func reduceFocusLease(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        let currentSnapshot = context.currentSnapshot
        switch event {
        case let .focusLeaseChanged(lease, _):
            setFocusSession(
                updatingFocusLease(
                    in: currentSnapshot.focusSession,
                    lease: lease
                ),
                current: currentSnapshot.focusSession,
                plan: &plan
            )
            if let lease {
                plan.notes = ["focus_lease=\(lease.owner.rawValue)", lease.reason].filter { !$0.isEmpty }
            } else {
                plan.notes = ["focus_lease=cleared"]
            }
        default:
            break
        }
    }

    static func reduceFocusRequest(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        let currentSnapshot = context.currentSnapshot
        switch event {
        case let .managedFocusRequested(token, workspaceId, monitorId, requestId, _):
            setFocusSession(
                managedFocusRequested(
                    from: currentSnapshot.focusSession,
                    token: token,
                    workspaceId: workspaceId,
                    monitorId: monitorId,
                    requestId: requestId
                ),
                current: currentSnapshot.focusSession,
                plan: &plan
            )
        case let .managedFocusConfirmed(token, workspaceId, monitorId, requestId, _):
            let focusSession = managedFocusConfirmed(
                from: currentSnapshot.focusSession,
                target: ManagedFocusConfirmation(
                    token: token,
                    workspaceId: workspaceId,
                    monitorId: monitorId,
                    requestId: requestId,
                    mode: currentSnapshot.windows.first(where: { $0.token == token })?.mode
                )
            )
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)
        default:
            break
        }
    }

    static func reduceFocusOwnership(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        let currentSnapshot = context.currentSnapshot
        switch event {
        case let .managedFocusCancelled(token, workspaceId, requestId, _):
            setFocusSession(
                managedFocusCancelled(
                    from: currentSnapshot.focusSession,
                    token: token,
                    workspaceId: workspaceId,
                    requestId: requestId
                ),
                current: currentSnapshot.focusSession,
                plan: &plan
            )
        case let .nativeFocusOwnerChanged(owner, preservePendingManagedFocus, _):
            var focusSession = currentSnapshot.focusSession
            focusSession.nativeFocusOwner = owner
            if case let .managed(token) = owner {
                focusSession.selectedManagedToken = token
                focusSession.recordWindowFocus(token)
            }
            if !preservePendingManagedFocus {
                focusSession.pendingManagedFocus = .empty
            }
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)
        default:
            break
        }
    }

    static func reduceFocusHistory(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        let currentSnapshot = context.currentSnapshot
        switch event {
        case let .focusRemembered(token, workspaceId, mode, _):
            var focusSession = currentSnapshot.focusSession
            if focusSession.rememberFocus(token, in: workspaceId, mode: mode) {
                plan.focusSession = focusSession
            }
        case let .focusFallbackRemembered(token, workspaceId, mode, _):
            var focusSession = currentSnapshot.focusSession
            if focusSession.rememberFocusFallback(token, in: workspaceId, mode: mode) {
                plan.focusSession = focusSession
            }
        case let .focusForgotten(workspaceIds, _):
            var focusSession = currentSnapshot.focusSession
            for workspaceId in workspaceIds {
                focusSession.lastTiledFocusedByWorkspace.removeValue(forKey: workspaceId)
                focusSession.lastFloatingFocusedByWorkspace.removeValue(forKey: workspaceId)
                focusSession.lastFocusedByWorkspace.removeValue(forKey: workspaceId)
            }
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)
        default:
            break
        }
    }

    static func reduceFocusSuppression(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        let currentSnapshot = context.currentSnapshot
        switch event {
        case let .suppressedFocusChanged(token, _):
            var focusSession = currentSnapshot.focusSession
            focusSession.suppressedFocusToken = token
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)
        case let .systemModalFocusChanged(token, _):
            var focusSession = currentSnapshot.focusSession
            focusSession.systemModalFocusToken = token
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)
        case let .nativeFullscreenPlaceholderSelected(token, _, _):
            var focusSession = currentSnapshot.focusSession
            focusSession.selectedManagedToken = token
            focusSession.recordWindowFocus(token)
            focusSession.nativeFocusOwner = .external(pid: token.pid, windowId: token.windowId)
            focusSession.clearPendingManagedFocus()
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)
        case let .interactionMonitorChanged(monitorId, previousMonitorId, _):
            var focusSession = currentSnapshot.focusSession
            focusSession.interactionMonitorId = monitorId
            focusSession.previousInteractionMonitorId = previousMonitorId
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)
        default:
            break
        }
    }

    static func reduceWorkspaceFocus(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        let currentSnapshot = context.currentSnapshot
        switch event {
        case let .workspaceFocusCleared(workspaceId, _):
            var focusSession = currentSnapshot.focusSession
            focusSession.clearPendingManagedFocus(
                matching: nil,
                workspaceId: workspaceId,
                requestId: focusSession.pendingManagedFocus.requestId
            )
            if let focusedToken = focusSession.selectedManagedToken,
               currentSnapshot.windows.first(where: { $0.token == focusedToken })?.workspaceId == workspaceId
            {
                focusSession.selectedManagedToken = nil
                if case .managed(focusedToken) = focusSession.nativeFocusOwner {
                    focusSession.nativeFocusOwner = .none
                } else if case let .external(identity) = focusSession.nativeFocusOwner,
                          identity.verifiedManagedParentToken == focusedToken
                {
                    focusSession.nativeFocusOwner = .external(identity.clearingVerifiedManagedParent())
                }
            }
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)
        default:
            break
        }
    }
}
