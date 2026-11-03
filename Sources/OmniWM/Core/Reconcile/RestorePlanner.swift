// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct RestorePlanner {
    private enum RestoreRefresh: String {
        case topology
        case activeSpace = "active_space"
        case systemWake = "system_wake"
        case systemSleep = "system_sleep"

        var refreshesIntents: Bool {
            self != .systemSleep
        }
    }

    struct EventInput {
        let event: WMEvent
        let snapshot: ReconcileSnapshot
        let monitors: [Monitor]
    }

    struct EventPlan: Equatable {
        var refreshRestoreIntents: Bool = false
        var interactionMonitorId: Monitor.ID?
        var previousInteractionMonitorId: Monitor.ID?
        var notes: [String] = []
    }

    struct FloatingRescueCandidate: Equatable {
        let token: WindowToken
        let pid: pid_t
        let windowId: Int
        let workspaceId: WorkspaceDescriptor.ID
        let targetMonitor: Monitor
        let currentFrame: CGRect?
        let targetFrame: CGRect
        let isScratchpadHidden: Bool
        let isWorkspaceInactiveHidden: Bool
    }

    struct FloatingRescueOperation: Equatable {
        let token: WindowToken
        let pid: pid_t
        let windowId: Int
        let workspaceId: WorkspaceDescriptor.ID
        let targetMonitor: Monitor
        let targetFrame: CGRect
    }

    struct FloatingRescuePlan: Equatable {
        var operations: [FloatingRescueOperation] = []

        var rescuedCount: Int {
            operations.count
        }
    }

    func planEvent(_ input: EventInput) -> EventPlan {
        var plan = EventPlan()

        if let refresh = restoreRefresh(for: input.event) {
            plan.refreshRestoreIntents = refresh.refreshesIntents
            plan.notes.append("restore_refresh=\(refresh.rawValue)")
        }

        let reconciled = reconcileInteractionMonitors(
            interactionMonitorId: input.snapshot.interactionMonitorId,
            previousInteractionMonitorId: input.snapshot.previousInteractionMonitorId,
            nativeManagedFocusToken: input.snapshot.nativeManagedFocusToken,
            windows: input.snapshot.windows,
            monitors: input.monitors
        )
        plan.interactionMonitorId = reconciled.interactionMonitorId
        plan.previousInteractionMonitorId = reconciled.previousInteractionMonitorId

        return plan
    }

    func planFloatingRescue(_ candidates: [FloatingRescueCandidate]) -> FloatingRescuePlan {
        var plan = FloatingRescuePlan()

        for candidate in candidates {
            guard !candidate.isScratchpadHidden else { continue }

            let needsRescue = candidate.currentFrame.map {
                candidate.isWorkspaceInactiveHidden || !$0.approximatelyEqual(
                    to: candidate.targetFrame,
                    tolerance: FrameTolerance.frameWrite
                )
            } ?? true
            guard needsRescue else { continue }

            plan.operations.append(
                FloatingRescueOperation(
                    token: candidate.token,
                    pid: candidate.pid,
                    windowId: candidate.windowId,
                    workspaceId: candidate.workspaceId,
                    targetMonitor: candidate.targetMonitor,
                    targetFrame: candidate.targetFrame
                )
            )
        }

        return plan
    }

    private func reconcileInteractionMonitors(
        interactionMonitorId: Monitor.ID?,
        previousInteractionMonitorId: Monitor.ID?,
        nativeManagedFocusToken: WindowToken?,
        windows: [ReconcileWindowSnapshot],
        monitors: [Monitor],
        visibleAssignments: [Monitor.ID: WorkspaceDescriptor.ID] = [:]
    ) -> (interactionMonitorId: Monitor.ID?, previousInteractionMonitorId: Monitor.ID?) {
        let validMonitorIds = Set(monitors.map(\.id))
        let focusedWorkspaceId = nativeManagedFocusToken.flatMap { token in
            windows.first(where: { $0.token == token })?.workspaceId
        }
        let focusedWorkspaceMonitorId = focusedWorkspaceId.flatMap { workspaceId in
            visibleAssignments.first(where: { $0.value == workspaceId })?.key
                ?? Monitor.sortedByPosition(monitors).first?.id
        }

        let resolvedInteractionMonitorId = interactionMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        } ?? focusedWorkspaceMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        } ?? monitors.first(where: \.isMain)?.id
            ?? Monitor.sortedByPosition(monitors).first?.id

        let resolvedPreviousInteractionMonitorId = previousInteractionMonitorId.flatMap {
            validMonitorIds.contains($0) ? $0 : nil
        }

        return (resolvedInteractionMonitorId, resolvedPreviousInteractionMonitorId)
    }

    private func restoreRefresh(for event: WMEvent) -> RestoreRefresh? {
        switch event {
        case .topologyChanged: .topology
        case .activeSpaceChanged: .activeSpace
        case .systemWake: .systemWake
        case .systemSleep: .systemSleep
        case .floatingGeometryUpdated,
             .hostedWindowGeometryObserved,
             .appVisibilityInvalidated,
             .floatingStateChanged,
             .focusFallbackRemembered,
             .focusForgotten,
             .focusLeaseChanged,
             .focusRemembered,
             .hiddenApplicationsChanged,
             .windowMinimizedChanged,
             .windowNativeWithdrawalChanged,
             .hiddenStateChanged,
             .interactionMonitorChanged,
             .layoutOperationPerformed,
             .managedFocusCancelled,
             .managedFocusConfirmed,
             .managedFocusRequested,
             .managedReplacementMetadataChanged,
             .manualLayoutOverrideChanged,
             .nativeFocusOwnerChanged,
             .nativeFullscreenPlaceholderSelected,
             .nativeFullscreenTransition,
             .niriPlacementsResolved,
             .dwindlePlacementsResolved,
             .scratchpadMembershipChanged,
             .scratchpadRevealChanged,
             .selectionChanged,
             .spaceTopologyChanged,
             .suppressedFocusChanged,
             .systemModalFocusChanged,
             .topLevelInventoryObserved,
             .userCommand,
             .viewportChanged,
             .viewportCommitted,
             .viewportForgotten,
             .visibleWorkspacesChanged,
             .windowAdmitted,
             .windowAdmissionHintsChanged,
             .windowModeChanged,
             .windowRekeyed,
             .windowRemoved,
             .workspaceAssigned,
             .workspaceFocusCleared:
            nil
        }
    }
}
