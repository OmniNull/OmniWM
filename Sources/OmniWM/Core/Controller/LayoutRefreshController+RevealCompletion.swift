// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    func hiddenRevealTerminalOutcome(
        for result: AXFrameApplyResult,
        transaction: PendingRevealTransaction
    ) -> HiddenRevealTerminalOutcome {
        if result.confirmedFrame != nil {
            guard let failureReason = result.writeResult.failureReason else {
                return .success
            }
            if isConfirmedRevealFailureTerminal(failureReason) {
                return .failure
            }
            if transaction.hiddenState.isScratchpad {
                return .delayedVerification
            }
            return .success
        }

        guard let failureReason = result.writeResult.failureReason else {
            return .failure
        }

        return isDelayedRevealRecoverable(failureReason) ? .delayedVerification : .failure
    }

    func finalizePendingRevealTransactionSuccess(
        forWindowId windowId: Int,
        confirmedFrame: CGRect?,
        transactionId: UInt64? = nil
    ) {
        defer { workspaceSwipe.checkSettlement() }
        guard let controller,
              let pendingTransaction = takePendingRevealTransaction(for: windowId, matching: transactionId)
        else {
            return
        }
        var revealSucceeded = false
        defer {
            revealGroups.settle(
                pendingTransaction,
                succeeded: revealSucceeded
            )
        }
        cancelPendingRevealVerification(for: windowId)
        guard !controller.workspaceManager.isAppHidden(pid: pendingTransaction.pid) else {
            controller.axManager.cancelPendingFrameJobs(
                [(pendingTransaction.pid, pendingTransaction.windowId)],
                reason: "scratchpad-reveal-app-hidden"
            )
            return
        }

        guard pendingRevealTransactionIsCurrent(pendingTransaction, using: controller.workspaceManager) else {
            restoreStalePendingRevealSideEffects(pendingTransaction, using: controller)
            requestRelayout(
                reason: .staleLayoutPlan,
                affectedWorkspaceIds: stalePendingRevealWorkspaceIds(pendingTransaction, using: controller)
            )
            return
        }
        applySuccessfulPendingReveal(pendingTransaction, confirmedFrame: confirmedFrame, controller: controller)
        revealSucceeded = true
    }

    func finalizePendingRevealTransactionFailure(
        forWindowId windowId: Int,
        transactionId: UInt64? = nil
    ) {
        defer { workspaceSwipe.checkSettlement() }
        guard let controller,
              let pendingTransaction = takePendingRevealTransaction(for: windowId, matching: transactionId)
        else {
            return
        }
        defer {
            revealGroups.settle(
                pendingTransaction,
                succeeded: false
            )
        }
        cancelPendingRevealVerification(for: windowId)
        let frameEntry = [(pendingTransaction.pid, pendingTransaction.windowId)]

        guard pendingRevealTransactionIsCurrent(pendingTransaction, using: controller.workspaceManager) else {
            restoreStalePendingRevealSideEffects(pendingTransaction, using: controller)
            requestRelayout(
                reason: .staleLayoutPlan,
                affectedWorkspaceIds: stalePendingRevealWorkspaceIds(pendingTransaction, using: controller)
            )
            return
        }

        let currentSiblingTransactions = pendingTransaction.revealGroupId.map {
            currentScratchpadRevealTransactionIds(
                in: $0,
                using: controller.workspaceManager
            )
        } ?? []
        defer {
            rebaseScratchpadRevealTransactions(
                currentSiblingTransactions,
                to: controller.workspaceManager.worldSeq
            )
        }

        restoreFailedRevealVisibility(pendingTransaction, frameEntry: frameEntry, controller: controller)
    }

    func restoreStalePendingRevealSideEffects(
        _ transaction: PendingRevealTransaction,
        using controller: WMController
    ) {
        let pendingFrameEntry = (pid: transaction.pid, windowId: transaction.windowId)
        guard let entry = controller.workspaceManager.entry(for: transaction.token) else {
            controller.axManager.suppressFrameWrites([pendingFrameEntry])
            return
        }

        let liveFrameEntry = (pid: entry.pid, windowId: entry.windowId)
        let frameEntries = liveFrameEntry.windowId == pendingFrameEntry.windowId
            ? [liveFrameEntry]
            : [pendingFrameEntry, liveFrameEntry]

        guard let hiddenState = controller.workspaceManager.hiddenState(for: transaction.token) else {
            controller.axManager.unsuppressFrameWrites(frameEntries)
            return
        }

        controller.axManager.cancelPendingFrameJobs(frameEntries, reason: "scratchpad-reveal-stale")
        controller.axManager.suppressFrameWrites(frameEntries)

        let monitor = stalePendingRevealMonitor(
            for: entry,
            hiddenState: hiddenState,
            transaction: transaction,
            using: controller
        )
        hideWindow(
            entry,
            monitor: monitor,
            side: hiddenState.offscreenSide ?? preferredHideSide(for: monitor),
            reason: hideReason(for: hiddenState)
        )
    }

    func stalePendingRevealWorkspaceIds(
        _ transaction: PendingRevealTransaction,
        using controller: WMController
    ) -> Set<WorkspaceDescriptor.ID> {
        var workspaceIds: Set<WorkspaceDescriptor.ID> = [transaction.workspaceId]
        if let currentWorkspaceId = controller.workspaceManager.entry(for: transaction.token)?.workspaceId {
            workspaceIds.insert(currentWorkspaceId)
        }
        return workspaceIds
    }

    func stalePendingRevealMonitor(
        for entry: WindowState,
        hiddenState: HiddenState,
        transaction: PendingRevealTransaction,
        using controller: WMController
    ) -> Monitor {
        hiddenState.referenceMonitorId.flatMap { controller.workspaceManager.monitor(byId: $0) }
            ?? controller.workspaceManager.monitor(byId: transaction.targetMonitorId)
            ?? controller.workspaceManager.monitor(for: entry.workspaceId)
            ?? Monitor.fallback()
    }

    func hideReason(for hiddenState: HiddenState) -> HideReason {
        switch hiddenState.reason {
        case .workspaceInactive:
            .workspaceInactive
        case .layoutTransient:
            .layoutTransient
        case .scratchpad:
            .scratchpad
        case .quake:
            .quake
        }
    }

    func delayedVerifiedRevealFrame(
        forWindowId windowId: Int,
        transactionId: UInt64
    ) -> CGRect? {
        guard let controller,
              let pendingTransaction = pendingRevealTransaction(for: windowId),
              pendingTransaction.id == transactionId,
              let entry = controller.workspaceManager.entry(for: pendingTransaction.token),
              !controller.workspaceManager.isWindowSuppressedByMacOS(entry.token),
              let observedFrame = observedWindowFrame(entry)
        else {
            return nil
        }

        let monitor = controller.workspaceManager.monitor(byId: pendingTransaction.targetMonitorId)
            ?? controller.workspaceManager.monitor(for: entry.workspaceId)
        guard let monitor else { return nil }
        guard observedFrame.intersects(monitor.visibleFrame),
              monitor.visibleFrame.contains(CGPoint(x: observedFrame.midX, y: observedFrame.midY))
        else {
            return nil
        }

        return observedFrame
    }
}

extension LayoutRefreshController {
    private func isDelayedRevealRecoverable(_ failureReason: AXFrameWriteFailureReason) -> Bool {
        switch failureReason {
        case .verificationMismatch,
             .readbackFailed,
             .sizeWriteFailed,
             .positionWriteFailed:
            return true
        default:
            return false
        }
    }

    private func isConfirmedRevealFailureTerminal(_ failureReason: AXFrameWriteFailureReason) -> Bool {
        switch failureReason {
        case .cancelled,
             .suppressed:
            return true
        default:
            return false
        }
    }
}

extension LayoutRefreshController {
    private func applySuccessfulPendingReveal(
        _ pendingTransaction: PendingRevealTransaction,
        confirmedFrame: CGRect?,
        controller: WMController
    ) {
        let actionWorkspacesCurrentAtEntry = pendingTransaction.postSuccessActions.map {
            $0.currentWorkspaces(using: controller.workspaceManager)
        }
        let currentSiblingTransactions = pendingTransaction.revealGroupId.map {
            currentScratchpadRevealTransactionIds(
                in: $0,
                using: controller.workspaceManager
            )
        } ?? []
        let focusSeqAccepted = controller.workspaceManager.isSeqCurrent(
            pendingTransaction.plannedSeq,
            for: pendingTransaction.workspaceId,
            domains: .focusCommit
        )
        controller.withRuntimeFrameJobCancellationSuppressed {
            controller.workspaceManager.setHiddenState(nil, for: pendingTransaction.token)
        }
        rebaseScratchpadRevealTransactions(
            currentSiblingTransactions,
            to: controller.workspaceManager.worldSeq
        )
        controller.axManager.clearParkPending(for: pendingTransaction.windowId, pid: pendingTransaction.pid)
        if pendingTransaction.hiddenState.isScratchpad {
            controller.requestWorkspaceBarRefresh()
        }
        if let confirmedFrame {
            controller.axManager.confirmFrameWrite(for: pendingTransaction.windowId, frame: confirmedFrame)
        }
        let acceptedSeqs: [WorkspaceDescriptor.ID: AcceptedSeq] = [
            pendingTransaction.workspaceId: AcceptedSeq(
                after: controller.workspaceManager.worldSeq,
                domains: focusSeqAccepted ? .layoutCommit.union(.focusCommit) : .layoutCommit
            )
        ]
        for (action, currentAtEntry) in zip(pendingTransaction.postSuccessActions, actionWorkspacesCurrentAtEntry) {
            action
                .forwarded(by: acceptedSeqs, currentAtEntry: currentAtEntry)
                .runIfCurrent(using: controller.workspaceManager)
        }
    }

    private func restoreFailedRevealVisibility(
        _ pendingTransaction: PendingRevealTransaction,
        frameEntry: [(pid: pid_t, windowId: Int)],
        controller: WMController
    ) {
        if pendingTransaction.hiddenState.isScratchpad,
           controller.workspaceManager.hiddenState(for: pendingTransaction.token)?.isScratchpad != true
        {
            controller.axManager.unsuppressFrameWrites(frameEntry)
            return
        }

        if pendingTransaction.hiddenState.workspaceInactive {
            controller.withRuntimeFrameJobCancellationSuppressed {
                controller.workspaceManager.setHiddenState(nil, for: pendingTransaction.token)
            }
            controller.axManager.unsuppressFrameWrites(frameEntry)
            return
        }

        if controller.workspaceManager.hiddenState(for: pendingTransaction.token) == nil {
            controller.withRuntimeFrameJobCancellationSuppressed {
                controller.workspaceManager.setHiddenState(
                    pendingTransaction.hiddenState,
                    for: pendingTransaction.token
                )
            }
        }
        if controller.workspaceManager.hiddenState(for: pendingTransaction.token) != nil {
            controller.axManager.suppressFrameWrites(frameEntry)
        }
    }
}
