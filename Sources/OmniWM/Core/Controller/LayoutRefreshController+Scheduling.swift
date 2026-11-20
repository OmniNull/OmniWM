// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    func enqueueRefresh(_ refresh: ScheduledRefresh) {
        performanceCounters?.refreshesEnqueued &+= 1
        if layoutState.inventoryStabilityHoldFullRescans,
           refresh.kind == .fullRescan
        {
            holdInventoryStabilityFullRescan(refresh, isNewerThanHeld: true)
            return
        }
        if refresh.visibilityTraceVisibility != nil {
            if layoutState.pendingRefresh != nil {
                recordVisibilityRefresh(refresh, outcome: .coalesced)
            } else if layoutState.activeRefresh != nil {
                recordVisibilityRefresh(refresh, outcome: .queued)
            }
        }
        if let activeRefresh = layoutState.activeRefresh {
            if refresh.kind == .immediateRelayout,
               activeRefresh.kind == .relayout || activeRefresh.kind == .visibilityRefresh
            {
                performanceCounters?.immediateRefreshRestarts &+= 1
            }
            handleRefresh(refresh, whileActive: activeRefresh)
            return
        }

        mergePendingRefresh(refresh)
        startNextRefreshIfNeeded()
    }

    func mergePendingRefresh(_ refresh: ScheduledRefresh) {
        guard let pendingRefresh = layoutState.pendingRefresh else {
            layoutState.pendingRefresh = refresh
            return
        }
        performanceCounters?.refreshesMerged &+= 1
        var merge = RefreshMerge(existing: pendingRefresh, incoming: refresh, controller: self)
        layoutState.pendingRefresh = merge.execute()
    }

    func startNextRefreshIfNeeded() {
        guard layoutState.activeRefreshTask == nil, let refresh = layoutState.pendingRefresh else { return }
        if layoutState.isRefreshSuspendedForLockScreen
            || controller?.isFrontmostAppLockScreen() == true
            || controller?.isLockScreenActive == true
        {
            performanceCounters?.lockedRefreshDeferrals &+= 1
            return
        }
        guard !layoutState.inventoryStabilityHoldFullRescans || refresh.kind != .fullRescan else { return }

        layoutState.pendingRefresh = nil
        layoutState.activeRefresh = refresh
        performanceCounters?.refreshesStarted &+= 1
        layoutState.didExecuteEffectPlan = false
        recordVisibilityRefresh(refresh, outcome: .started)
        let refreshGeneration = layoutState.refreshGeneration
        layoutState.activeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didComplete = await self.execute(refresh, generation: refreshGeneration)
            self.finishRefresh(refresh, didComplete: didComplete, generation: refreshGeneration)
        }
    }

    func suspendForLockScreen() {
        layoutState.isAwaitingPostUnlockTopologySample = false
        guard !layoutState.isRefreshSuspendedForLockScreen else { return }
        layoutState.isRefreshSuspendedForLockScreen = true
        layoutState.activeRefreshTask?.cancel()
    }

    func awaitPostUnlockTopologySample() {
        guard layoutState.isRefreshSuspendedForLockScreen else { return }
        layoutState.isAwaitingPostUnlockTopologySample = true
    }

    func resumeAfterPostUnlockTopologySample() {
        guard layoutState.isAwaitingPostUnlockTopologySample else { return }
        layoutState.isAwaitingPostUnlockTopologySample = false
        layoutState.isRefreshSuspendedForLockScreen = false
        startNextRefreshIfNeeded()
    }

    func finishRefresh(_ refresh: ScheduledRefresh, didComplete: Bool, generation: UInt64) {
        guard generation == layoutState.refreshGeneration else {
            recordVisibilityRefresh(
                layoutState.activeRefresh ?? refresh,
                outcome: .invalidated,
                reason: .generationInvalidated
            )
            return
        }
        let completedRefresh = layoutState.activeRefresh ?? refresh
        let didExecuteEffectPlan = layoutState.didExecuteEffectPlan

        if !didComplete {
            if var counters = performanceCounters {
                counters.refreshesIncomplete &+= 1
                counters.consecutiveRequeues &+= 1
                counters.maximumConsecutiveRequeues = max(
                    counters.maximumConsecutiveRequeues,
                    counters.consecutiveRequeues
                )
                performanceCounters = counters
            }
            preserveCancelledRefreshState(completedRefresh)
        } else {
            performanceCounters?.refreshesCompleted &+= 1
            performanceCounters?.consecutiveRequeues = 0
        }

        layoutState.activeRefreshTask = nil
        layoutState.activeRefresh = nil
        layoutState.didExecuteEffectPlan = false
        recordVisibilityRefresh(
            completedRefresh,
            outcome: didComplete ? .completed : .invalidated
        )

        if didComplete {
            recordCompletedLayoutCycle()
            completeRefreshActions(completedRefresh, didExecuteEffectPlan: didExecuteEffectPlan)
            collectUnusedWorkspacesIfIdle()
        }

        controller?.niriLayoutHandler.scheduleOverflowCheck()
        startNextRefreshIfNeeded()
    }

    func collectUnusedWorkspacesIfIdle() {
        guard let controller,
              layoutState.activeRefresh == nil,
              !controller.isOverviewOpen(),
              workspaceSwipe.preparation == nil,
              !workspaceSwipe.hasPresentation
        else { return }
        controller.workspaceManager.garbageCollectUnusedWorkspaces(
            focusedWorkspaceId: controller.activeWorkspace()?.id
        )
    }

    func completeRefreshActions(_ completedRefresh: ScheduledRefresh, didExecuteEffectPlan: Bool) {
        if !didExecuteEffectPlan, let controller {
            let shouldRequestWorkspaceBarRefresh =
                completedRefresh.kind != .visibilityRefresh && completedRefresh.needsVisibilityReconciliation

            for postLayoutAction in completedRefresh.postLayoutActions {
                postLayoutAction.runIfCurrent(using: controller.workspaceManager)
            }
            if shouldRequestWorkspaceBarRefresh {
                controller.requestWorkspaceBarRefresh()
            }
        }
        if let followUpRefresh = completedRefresh.followUpRefresh {
            let affectedWorkspaceIds = resolvedFollowUpWorkspaceIds(
                followUpRefresh
            )
            let refresh = ScheduledRefresh(
                kind: followUpRefresh.kind,
                reason: followUpRefresh.reason,
                affectedWorkspaceIds: affectedWorkspaceIds,
                workspaceMonitorRelocations: Array(
                    followUpRefresh.workspaceMonitorRelocations.values
                ),
                reconcilesWorkspaceMonitorState: followUpRefresh.reconcilesWorkspaceMonitorState,
                suppressesWindowActivation: completedRefresh.suppressesWindowActivation
                    || followUpRefresh.suppressesWindowActivation
            )
            let newerPendingRefresh = layoutState.pendingRefresh
            layoutState.pendingRefresh = refresh
            if let newerPendingRefresh {
                mergePendingRefresh(newerPendingRefresh)
            }
        }
    }
}
