// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    @discardableResult
    func recordReconcileEvent(_ event: WMEvent) -> ReconcileTxn {
        if case let .viewportForgotten(workspaceIds, _) = event {
            removeAnimationMotions(for: workspaceIds)
        }
        let previousFocus = focusSessionSnapshot
        let viewportWorkspaceId = viewportWorkspaceId(for: event)
        let previousViewport = viewportWorkspaceId.flatMap { recordedViewportStates[$0] }
        let txn = commitWorldEvent(
            event,
            monitors: monitors,
            resolvePlan: { plan, token, snapshot in
                let plan = self.resolvedRestorePlan(plan, for: token, event: event, snapshot: snapshot)
                return self.applyActionPlan(plan, to: token)
            }
        )
        if case let .workspaceAssigned(token, _, destination, _, _) = event,
           entry(for: token)?.target.hostedMetadata?.role == .main
        {
            onHostedFamilyWorkspaceChanged?(token, destination)
        }
        if txn.plan.mutatesRuntimeState || eventRequiresRuntimeInvalidation(event) {
            noteInvalidation(for: event)
        }
        noteAuxiliaryFocusInvalidationIfNeeded(for: event, previousFocus: previousFocus, plan: txn.plan)
        if let viewportWorkspaceId {
            noteViewportInvalidationIfNeeded(
                for: viewportWorkspaceId,
                previousViewport: previousViewport,
                pendingOffsetAnimation: viewportEventState(for: event)?.hasPendingOffsetAnimation == true
            )
            if let eventState = viewportEventState(for: event) {
                animationDriver.reconcileViewportCommit(
                    workspaceId: viewportWorkspaceId,
                    previous: previousViewport,
                    next: recordedViewportStates[viewportWorkspaceId] ?? eventState,
                    transition: eventState.offsetTransition
                )
            }
        }
        return txn
    }

    private func resolvedRestorePlan(
        _ plan: ActionPlan,
        for token: WindowToken?,
        event: WMEvent,
        snapshot: ReconcileSnapshot
    ) -> ActionPlan {
        var plan = plan
        let restoreEventPlan = RestorePlanner().planEvent(
            .init(
                event: event,
                snapshot: snapshot,
                monitors: monitors
            )
        )
        if let restoreRefresh = plannedRestoreRefresh(
            from: restoreEventPlan,
            snapshot: snapshot
        ) {
            plan.restoreRefresh = restoreRefresh
        }
        if let token, let persistedHydration = plannedPersistedHydrationMutation(for: token) {
            plan = mergePersistedHydration(
                persistedHydration,
                into: plan,
                existingEntry: windowQueries.entry(for: token)
            )
        }
        if !restoreEventPlan.notes.isEmpty {
            plan.notes.append(contentsOf: restoreEventPlan.notes)
        }
        return plan
    }
}
