// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension StateReducer {
    static func reduceAdmission(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        let existingEntry = context.existingEntry
        let currentSnapshot = context.currentSnapshot
        let windowExistedBeforeMutation = context.windowExistedBeforeMutation
        switch event {
        case let .windowAdmitted(token, workspaceId, monitorId, mode, _, _, _, _, adoptNativeFocus, _, _, initialFrame):
            plan.lifecyclePhase = lifecyclePhase(for: mode)
            var observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            if let initialFrame {
                observedState.frame = initialFrame
            }
            plan.observedState = observedState
            plan.desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: mode
            )
            if !windowExistedBeforeMutation,
               adoptNativeFocus,
               currentSnapshot.focusSession.pendingManagedFocus == .empty,
               currentSnapshot.focusSession.nativeFocusOwner.externalToken == token
            {
                var focusSession = adoptingManagedFocus(
                    in: currentSnapshot.focusSession,
                    token: token,
                    monitorId: monitorId,
                    mode: mode
                )
                _ = focusSession.rememberFocus(token, in: workspaceId, mode: mode)
                plan.focusSession = focusSession
            }
        default:
            break
        }
    }

    static func reduceIdentity(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        let existingEntry = context.existingEntry
        let currentSnapshot = context.currentSnapshot
        switch event {
        case let .windowRekeyed(from, to, workspaceId, monitorId, _, _, _, _):
            plan.lifecyclePhase = .replacing
            plan.observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            plan.desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: existingEntry?.mode ?? .tiling
            )
            plan.focusSession = rekeyedFocusSession(
                from: currentSnapshot.focusSession,
                oldToken: from,
                newToken: to
            )
        case let .windowRemoved(token, workspaceId, _):
            plan.lifecyclePhase = .destroyed
            plan.focusSession = removingFocusState(
                from: currentSnapshot.focusSession,
                token: token,
                workspaceId: workspaceId
            )
        default:
            break
        }
    }

    static func reduceWorkspaceAssignment(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        let existingEntry = context.existingEntry
        let currentSnapshot = context.currentSnapshot
        switch event {
        case let .workspaceAssigned(token, sourceWorkspaceId, workspaceId, monitorId, _):
            plan.observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            plan.desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: existingEntry?.mode ?? .tiling
            )
            if let focusSession = reassigningFocusState(
                from: currentSnapshot.focusSession,
                token: token,
                sourceWorkspaceId: sourceWorkspaceId,
                workspaceId: workspaceId
            ) {
                plan.focusSession = focusSession
            }
        case let .windowModeChanged(token, workspaceId, monitorId, mode, _):
            plan.lifecyclePhase = lifecyclePhase(for: mode)
            plan.observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            plan.desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId,
                mode: mode
            )
            var focusSession = currentSnapshot.focusSession
            if focusSession.reconcileRememberedFocus(afterModeChangeOf: token, in: workspaceId, to: mode) {
                plan.focusSession = focusSession
            }
        default:
            break
        }
    }

    static func reduceHostedGeometry(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        guard case let .hostedWindowGeometryObserved(_, _, monitorId, frame, _) = event,
              let entry = context.existingEntry, entry.target.hostedMetadata != nil else { return }
        var observed = entry.observedState
        observed.frame = frame
        if let monitorId { observed.monitorId = monitorId }
        plan.observedState = observed
        if entry.mode == .floating {
            var desired = entry.desiredState
            desired.floatingFrame = frame
            if let monitorId { desired.monitorId = monitorId }
            plan.desiredState = desired
        }
    }

    static func reduceFloatingState(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        let existingEntry = context.existingEntry
        switch event {
        case let .floatingGeometryUpdated(_, workspaceId, referenceMonitorId, frame, _, restoreToFloating, _):
            plan.lifecyclePhase = .floating
            var observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: referenceMonitorId ?? existingEntry?.observedState.monitorId
            )
            observedState.frame = frame
            plan.observedState = observedState

            var desiredState = baseDesiredState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: referenceMonitorId ?? existingEntry?.desiredState.monitorId,
                mode: .floating
            )
            desiredState.floatingFrame = frame
            desiredState.rescueEligible = restoreToFloating
            plan.desiredState = desiredState
        case let .floatingStateChanged(_, _, state, _):
            plan.notes = ["floating_state=\(state != nil)"]
        case let .manualLayoutOverrideChanged(_, _, layoutOverride, _):
            plan.notes = ["manual_layout_override=\(layoutOverride.map(\.rawValue) ?? "cleared")"]
        case .windowAdmissionHintsChanged:
            break
        case .topLevelInventoryObserved:
            break
        default:
            break
        }
    }

    static func reduceApplicationVisibility(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        let currentSnapshot = context.currentSnapshot
        switch event {
        case let .hiddenApplicationsChanged(pids, affectedWorkspaceIds, _):
            var focusSession = currentSnapshot.focusSession
            if let pendingToken = focusSession.pendingManagedFocus.token,
               pids.contains(pendingToken.pid)
            {
                focusSession.pendingManagedFocus = .empty
            }
            switch focusSession.nativeFocusOwner {
            case let .managed(token) where pids.contains(token.pid):
                focusSession.nativeFocusOwner = .external(pid: nil, windowId: nil)
            case let .external(identity) where identity.pid.map(pids.contains) == true:
                focusSession.nativeFocusOwner = .external(identity.downgradingToPIDOnly())
            case let .external(identity)
                where identity.verifiedManagedParentToken.map({ pids.contains($0.pid) }) == true:
                focusSession.nativeFocusOwner = .external(identity.clearingVerifiedManagedParent())
            case .managed,
                 .external,
                 .ownedSurface,
                 .none:
                break
            }
            setFocusSession(focusSession, current: currentSnapshot.focusSession, plan: &plan)
            plan.notes = ["hidden_apps=\(pids.count)", "workspaces=\(affectedWorkspaceIds.count)"]
        case let .appVisibilityInvalidated(pid, affectedWorkspaceIds, _):
            plan.notes = ["app_visibility_invalidated=\(pid)", "workspaces=\(affectedWorkspaceIds.count)"]
        default:
            break
        }
    }

    static func reduceWindowVisibility(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) {
        let existingEntry = context.existingEntry
        switch event {
        case let .hiddenStateChanged(_, workspaceId, monitorId, hiddenState, _):
            var observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            observedState.isVisible = hiddenState == nil
            plan.observedState = observedState
            if let hiddenState {
                plan.lifecyclePhase = hiddenState.offscreenSide == nil ? .hidden : .offscreen
            } else {
                plan.lifecyclePhase = lifecyclePhase(for: existingEntry?.mode ?? .tiling)
            }
        case let .nativeFullscreenTransition(_, workspaceId, monitorId, change, _):
            var observedState = baseObservedState(
                from: existingEntry,
                workspaceId: workspaceId,
                monitorId: monitorId
            )
            observedState.isNativeFullscreen = change.isNativeFullscreenActive
            plan.observedState = observedState
            plan.lifecyclePhase = change.isNativeFullscreenActive
                ? .nativeFullscreen
                : lifecyclePhase(for: existingEntry?.mode ?? .tiling)
        default:
            break
        }
    }
}
