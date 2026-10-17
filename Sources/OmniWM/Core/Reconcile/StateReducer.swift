// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum StateReducer {
    struct ReductionContext {
        let existingEntry: WindowState?
        let currentSnapshot: ReconcileSnapshot
        let windowExistedBeforeMutation: Bool
    }

    static func reduce(
        event: WMEvent,
        existingEntry: WindowState?,
        currentSnapshot: ReconcileSnapshot,
        monitors: [Monitor],
        windowExistedBeforeMutation: Bool = false
    ) -> ActionPlan {
        var plan = ActionPlan()

        let context = ReductionContext(
            existingEntry: existingEntry,
            currentSnapshot: currentSnapshot,
            windowExistedBeforeMutation: windowExistedBeforeMutation
        )
        switch event.reconcileDomain {
        case .window:
            _ = reduceWindowEvent(event, context: context, plan: &plan)
        case .focus:
            _ = reduceFocusEvent(event, context: context, plan: &plan)
        case .session:
            _ = reduceSessionEvent(event, context: context, plan: &plan)
        case .viewport:
            _ = reduceViewportEvent(event, context: context, plan: &plan)
        }

        if plan.restoreIntent == nil, plan.mutatesRuntimeState, let existingEntry {
            let restoreIntent = restoreIntent(for: existingEntry, monitors: monitors)
            if existingEntry.restoreIntent != restoreIntent {
                plan.restoreIntent = restoreIntent
            }
        }

        return plan
    }

    static func restoreIntent(
        for entry: WindowState,
        monitors: [Monitor]
    ) -> RestoreIntent {
        let preferredMonitorId = entry.desiredState.monitorId
            ?? entry.observedState.monitorId
            ?? entry.floatingState?.referenceMonitorId
        let preferredMonitor = preferredMonitorId.flatMap { id in
            monitors.first { $0.id == id }
        }
        let floatingState = entry.floatingState
        let hasDetachedNiriPlacement = entry.restoreIntent?.detachedNiriContainerSizingState != nil
        let staysOnRestoreWorkspace = entry.restoreIntent?.workspaceId == entry.workspaceId
        let keepsTilingPlacement = entry.mode == .tiling && staysOnRestoreWorkspace
        let preservesNiriPlacement = hasDetachedNiriPlacement || keepsTilingPlacement
        let preservedNiriPlacement = preservesNiriPlacement ? entry.restoreIntent?.niriPlacement : nil
        let niriPlacement = staysOnRestoreWorkspace
            ? preservedNiriPlacement
            : preservedNiriPlacement?.withoutColumnPosition
        return RestoreIntent(
            topologyProfile: TopologyProfile(monitors: monitors),
            workspaceId: entry.workspaceId,
            preferredMonitor: preferredMonitor.map(DisplayFingerprint.init),
            floatingFrame: entry.desiredState.floatingFrame ?? floatingState?.lastFrame,
            normalizedFloatingOrigin: floatingState?.normalizedOrigin,
            restoreToFloating: entry.mode == .floating,
            rescueEligible: entry.desiredState.rescueEligible || floatingState?.restoreToFloating == true,
            niriPlacement: niriPlacement,
            detachedNiriContainerSizingState: entry.restoreIntent?.detachedNiriContainerSizingState,
            dwindlePlacement: keepsTilingPlacement ? entry.restoreIntent?.dwindlePlacement : nil
        )
    }

    static func replay(_ trace: [ReconcileTraceRecord]) -> [ActionPlan] {
        trace.map(\.plan)
    }

    static func lifecyclePhase(for mode: TrackedWindowMode) -> WindowLifecyclePhase {
        switch mode {
        case .tiling:
            .tiled
        case .floating:
            .floating
        }
    }

    static func baseObservedState(
        from entry: WindowState?,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?
    ) -> ObservedWindowState {
        var state = entry?.observedState ?? ObservedWindowState.initial(
            workspaceId: workspaceId,
            monitorId: monitorId
        )
        state.workspaceId = workspaceId
        state.monitorId = monitorId ?? state.monitorId
        return state
    }

    static func baseDesiredState(
        from entry: WindowState?,
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID?,
        mode: TrackedWindowMode
    ) -> DesiredWindowState {
        var state = entry?.desiredState ?? DesiredWindowState.initial(
            workspaceId: workspaceId,
            monitorId: monitorId,
            disposition: mode
        )
        state.workspaceId = workspaceId
        state.monitorId = monitorId ?? state.monitorId
        state.disposition = mode
        state.rescueEligible = mode == .floating || state.rescueEligible
        return state
    }

    private static func reduceWindowEvent(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) -> Bool {
        switch event {
        case .windowAdmitted:
            reduceAdmission(event, context: context, plan: &plan)
            return true
        case .windowRekeyed,
             .windowRemoved:
            reduceIdentity(event, context: context, plan: &plan)
            return true
        case .workspaceAssigned,
             .windowModeChanged:
            reduceWorkspaceAssignment(event, context: context, plan: &plan)
            return true
        case .floatingGeometryUpdated,
             .floatingStateChanged,
             .manualLayoutOverrideChanged,
             .windowAdmissionHintsChanged,
             .topLevelInventoryObserved:
            reduceFloatingState(event, context: context, plan: &plan)
            return true
        case .niriPlacementsResolved,
             .dwindlePlacementsResolved,
             .layoutOperationPerformed,
             .managedReplacementMetadataChanged:
            reducePlacementNotes(event, context: context, plan: &plan)
            return true
        case .windowMinimizedChanged,
             .windowNativeWithdrawalChanged:
            reduceNativeWindowSuppression(event, context: context, plan: &plan)
            return true
        case .hiddenApplicationsChanged,
             .appVisibilityInvalidated:
            reduceApplicationVisibility(event, context: context, plan: &plan)
            return true
        case .hiddenStateChanged,
             .nativeFullscreenTransition:
            reduceWindowVisibility(event, context: context, plan: &plan)
            return true
        default:
            return false
        }
    }

    private static func reduceFocusEvent(_ event: WMEvent, context: ReductionContext, plan: inout ActionPlan) -> Bool {
        switch event {
        case .focusLeaseChanged:
            reduceFocusLease(event, context: context, plan: &plan)
            return true
        case .managedFocusRequested,
             .managedFocusConfirmed:
            reduceFocusRequest(event, context: context, plan: &plan)
            return true
        case .managedFocusCancelled,
             .nativeFocusOwnerChanged:
            reduceFocusOwnership(event, context: context, plan: &plan)
            return true
        case .focusRemembered,
             .focusFallbackRemembered,
             .focusForgotten:
            reduceFocusHistory(event, context: context, plan: &plan)
            return true
        case .suppressedFocusChanged,
             .systemModalFocusChanged,
             .nativeFullscreenPlaceholderSelected,
             .interactionMonitorChanged:
            reduceFocusSuppression(event, context: context, plan: &plan)
            return true
        case .workspaceFocusCleared:
            reduceWorkspaceFocus(event, context: context, plan: &plan)
            return true
        default:
            return false
        }
    }

    private static func reduceViewportEvent(
        _ event: WMEvent,
        context: ReductionContext,
        plan: inout ActionPlan
    ) -> Bool {
        switch event {
        case .viewportChanged,
             .viewportCommitted,
             .viewportForgotten,
             .selectionChanged:
            reduceViewport(event, context: context, plan: &plan)
            return true
        default:
            return false
        }
    }

    private static func reduceSessionEvent(
        _ event: WMEvent,
        context: ReductionContext,
        plan: inout ActionPlan
    ) -> Bool {
        switch event {
        case .scratchpadMembershipChanged,
             .scratchpadRevealChanged,
             .visibleWorkspacesChanged,
             .spaceTopologyChanged,
             .topologyChanged,
             .activeSpaceChanged,
             .systemSleep,
             .systemWake,
             .userCommand:
            reduceSessionNotes(event, context: context, plan: &plan)
            return true
        default:
            return false
        }
    }
}
