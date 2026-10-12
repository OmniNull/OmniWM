// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

@MainActor final class LayoutRefreshController: NSObject {
    typealias PostLayoutAction = @MainActor () -> Void

    @MainActor
    private final class RefreshFrameContext {
        private var cache: [WindowToken: CGRect?] = [:]
        private(set) var requests = 0
        private(set) var hits = 0

        func fastFrame(for token: WindowToken, axRef: AXWindowRef) -> CGRect? {
            requests += 1
            if let cached = cache[token] {
                hits += 1
                return cached
            }
            let frame = AXWindowService.framePreferFast(axRef)
            cache[token] = .some(frame)
            return frame
        }
    }

    weak var controller: WMController?
    static let hiddenWindowEdgeRevealEpsilon: CGFloat = 1.0
    private static let delayedRevealVerificationDelay: Duration = .milliseconds(50)

    enum HideReason {
        case workspaceInactive
        case layoutTransient
        case scratchpad
    }

    enum HiddenRevealTerminalOutcome {
        case success
        case delayedVerification
        case failure
    }

    struct ScratchpadRevealOutcome {
        let revealedHandles: [WindowHandle]
    }

    struct PendingRevealTransaction {
        let id: UInt64
        var token: WindowToken
        var pid: pid_t
        var windowId: Int
        var workspaceId: WorkspaceDescriptor.ID
        var plannedSeq: UInt64
        let targetFrame: CGRect
        let targetMonitorId: Monitor.ID
        let hiddenState: HiddenState
        var postSuccessActions: [RefreshPostLayoutAction]
        var delayedVerificationScheduled: Bool = false
        var revealGroupId: UInt64?
    }

    var layoutState = LayoutRefreshState()
    private var layoutBuildMetrics = LayoutBuildMetrics()
    var displayTickMetrics = DisplayTickMetrics()
    var performanceCounters: PerformanceCounters?
    var displayLinkActivationForTests: ((CGDirectDisplayID) -> Bool)?
    var displayLinkCreationAllowedForTests: ((CGDirectDisplayID) -> Bool)?
    var activeDisplayLinkCountForTests: (() -> Int)?
    var fullRescanEnumerationSnapshotForTests: AXManager.FullRescanEnumerationSnapshot?
    private var activeFrameContext: RefreshFrameContext?
    private var nextPendingRevealTransactionId: UInt64 = 1
    private var pendingRevealTransactionsByWindowId: [Int: PendingRevealTransaction] = [:]
    private var pendingRevealVerificationTasksByWindowId: [Int: Task<Void, Never>] = [:]
    private(set) lazy var revealGroups = ScratchpadRevealGroups(controller: controller)
    var closingAnimationIdsByObjectId: [ObjectIdentifier: UUID] = [:]
    var lastSubmittedClosingFramesByAnimationId: [UUID: CGRect] = [:]
    var nativeFullscreenRestoredFrameApplyTokens: Set<WindowToken> = []

    var fastFrameProvider: (WindowToken, AXWindowRef) -> CGRect? = { _, axRef in
        AXWindowService.framePreferFast(axRef)
    }

    var nativeSpaceWindowInventoryProvider: (Set<UInt64>) -> NativeSpaceWindowInventoryResult = {
        SkyLight.shared.nativeSpaceWindowInventory(spaceIds: $0)
    }

    func fastFrame(for token: WindowToken, axRef: AXWindowRef) -> CGRect? {
        activeFrameContext?.fastFrame(for: token, axRef: axRef)
            ?? fastFrameProvider(token, axRef)
    }

    private(set) lazy var niriHandler = NiriLayoutHandler(controller: controller)
    lazy var workspaceSwipe = WorkspaceSwipePresentation(refreshController: self)
    private(set) lazy var dwindleHandler = DwindleLayoutHandler(controller: controller)
    private lazy var diffExecutor = LayoutDiffExecutor(refreshController: self)

    var isDiscoveryInProgress: Bool {
        layoutState.activeFullEnumerationCount > 0
    }

    init(controller: WMController) {
        self.controller = controller
        super.init()
    }

    func executeEffectPlan(_ plan: EffectPlan, generation: UInt64) -> Bool {
        guard let controller else { return false }
        guard isCurrentRefreshGeneration(generation) else { return false }

        activeFrameContext = RefreshFrameContext()
        defer { activeFrameContext = nil }

        applyEffectPlan(plan, controller: controller)

        return true
    }

    func resetState() {
        workspaceSwipe.cancel(reason: "reset")
        let discardedScratchpadIndices = revealGroups.indices()
        layoutState.activeRefreshTask?.cancel()
        layoutState.activeRefreshTask = nil
        layoutState.pendingDebounceTask?.cancel()
        layoutState.pendingDebounceTask = nil
        layoutState.missingConfirmationTask?.cancel()
        layoutState.missingConfirmationTask = nil
        layoutState.pendingMissingConfirmationScope = nil
        layoutState.consecutiveMissCountByHandle.removeAll(keepingCapacity: true)
        layoutState.inventoryStabilityBarrierActive = false
        layoutState.inventoryStabilityHoldFullRescans = false
        layoutState.inventoryStabilityHeldFullRescan = nil
        layoutState.trailingAuditTask?.cancel()
        layoutState.trailingAuditTask = nil
        layoutState.activeRefresh = nil
        layoutState.pendingRefresh = nil
        layoutState.isRefreshSuspendedForLockScreen = false
        layoutState.isAwaitingPostUnlockTopologySample = false
        layoutState.didExecuteEffectPlan = false
        layoutState.refreshGeneration &+= 1
        for (_, task) in pendingRevealVerificationTasksByWindowId {
            task.cancel()
        }
        pendingRevealVerificationTasksByWindowId.removeAll()
        pendingRevealTransactionsByWindowId.removeAll()
        revealGroups.discardAll()
        for index in discardedScratchpadIndices {
            reconcileRevealedScratchpadAfterGroupDiscard(index)
        }
        nextPendingRevealTransactionId = 1
        revealGroups.resetIdentitySequence()
        dwindleHandler.groupReveals.resetPendingGroupReveals()
        nativeFullscreenRestoredFrameApplyTokens.removeAll()

        resetDisplayLinkAndAnimationState()

        controller?.axManager.clearInactiveWorkspaceWindows()
        layoutState.backingScaleByDisplay = nil

        if let observer = layoutState.screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            layoutState.screenChangeObserver = nil
        }
    }

    func displayTickMetricsSnapshot() -> DisplayTickMetrics {
        displayTickMetrics
    }

    func layoutBuildMetricsCounts() -> (totalBuilds: Int, completedRelayoutCycles: Int) {
        (layoutBuildMetrics.totalBuilds, layoutBuildMetrics.completedRelayoutCycles)
    }

    func layoutBuildMetricsDump() -> String {
        layoutBuildMetrics.dump()
    }

    func recordScrollBuild(seconds: Double, workspaceCount: Int, windowCount: Int) {
        recordLayoutBuild(
            seconds: seconds,
            route: .scrollTick,
            workspaceCount: workspaceCount,
            windowCount: windowCount
        )
    }
}

extension LayoutRefreshController {
    func discardScratchpadRevealGroupAndReconcile(_ groupId: UInt64) {
        guard let index = revealGroups.discard(groupId) else { return }
        reconcileRevealedScratchpadAfterGroupDiscard(index)
    }

    func reconcileRevealedScratchpadAfterGroupDiscard(_ index: ScratchpadIndex) {
        guard let controller,
              controller.workspaceManager.revealedScratchpadIndex() == index,
              !controller.workspaceManager.scratchpadMembers(in: index).contains(where: {
                  controller.isManagedWindowDisplayable($0)
              })
        else {
            return
        }
        controller.workspaceManager.setRevealedScratchpad(nil)
        controller.requestWorkspaceBarRefresh()
    }
}

extension LayoutRefreshController {
    func recordLayoutBuild(seconds: Double, route: LayoutBuildMetrics.Route, workspaceCount: Int, windowCount: Int) {
        layoutBuildMetrics.recordBuild(
            seconds: seconds,
            route: route,
            workspaceCount: workspaceCount,
            windowCount: windowCount
        )
    }

    func recordCompletedLayoutCycle() {
        layoutBuildMetrics.recordCompletedCycle()
    }

    func pendingRevealTransaction(for windowId: Int) -> PendingRevealTransaction? {
        pendingRevealTransactionsByWindowId[windowId]
    }

    func takePendingRevealTransaction(for windowId: Int, matching transactionId: UInt64?) -> PendingRevealTransaction? {
        guard let pending = pendingRevealTransactionsByWindowId.removeValue(forKey: windowId) else { return nil }
        if let transactionId, pending.id != transactionId {
            pendingRevealTransactionsByWindowId[windowId] = pending
            return nil
        }
        return pending
    }

    func cancelPendingRevealVerification(for windowId: Int) {
        pendingRevealVerificationTasksByWindowId.removeValue(forKey: windowId)?.cancel()
    }
}

extension LayoutRefreshController {
    func hasPendingRevealTransaction(for windowId: Int) -> Bool {
        pendingRevealTransactionsByWindowId[windowId] != nil
    }

    func pendingRevealTransactionId(forWindowId windowId: Int) -> UInt64? {
        pendingRevealTransactionsByWindowId[windowId]?.id
    }

    func currentScratchpadRevealTransactionIds(
        in groupId: UInt64,
        using workspaceManager: WorkspaceManager
    ) -> Set<UInt64> {
        Set(pendingRevealTransactionsByWindowId.values.compactMap { transaction in
            guard transaction.revealGroupId == groupId,
                  pendingRevealTransactionIsCurrent(transaction, using: workspaceManager)
            else {
                return nil
            }
            return transaction.id
        })
    }

    func rebaseScratchpadRevealTransactions(
        _ transactionIds: Set<UInt64>,
        to plannedSeq: UInt64
    ) {
        guard !transactionIds.isEmpty else { return }
        for (windowId, var transaction) in pendingRevealTransactionsByWindowId
            where transactionIds.contains(transaction.id)
        {
            transaction.plannedSeq = plannedSeq
            pendingRevealTransactionsByWindowId[windowId] = transaction
        }
    }

    func shouldUsePendingRevealTransaction(
        for entry: WindowState,
        hiddenState: HiddenState
    ) -> Bool {
        !hiddenState.workspaceInactive
            && entry.mode == .floating
            && hiddenState.restoresViaFloatingState
    }

    func beginPendingRevealTransaction(
        for entry: WindowState,
        hiddenState: HiddenState,
        targetFrame: CGRect,
        monitor: Monitor,
        onSuccess: PostLayoutAction? = nil,
        revealGroupId: UInt64? = nil
    ) -> UInt64? {
        guard let controller else { return nil }
        let entry = controller.workspaceManager.entry(for: entry.token) ?? entry
        if var pendingTransaction = pendingRevealTransactionsByWindowId[entry.windowId] {
            if let revealGroupId {
                if let previousGroupId = pendingTransaction.revealGroupId,
                   previousGroupId != revealGroupId
                {
                    revealGroups.detach(pendingTransaction.id, groupId: previousGroupId)
                }
                pendingTransaction.revealGroupId = revealGroupId
                if pendingTransaction.hiddenState.isScratchpad {
                    pendingTransaction.postSuccessActions.removeAll(keepingCapacity: false)
                }
                pendingRevealTransactionsByWindowId[entry.windowId] = pendingTransaction
                revealGroups.register(pendingTransaction.id, groupId: revealGroupId)
                return nil
            }
            if let onSuccess = makePostLayoutAction(
                onSuccess,
                workspaceIds: [entry.workspaceId]
            ) {
                if !pendingTransaction.hiddenState.isScratchpad || pendingTransaction.postSuccessActions.isEmpty {
                    pendingTransaction.postSuccessActions.append(onSuccess)
                    pendingRevealTransactionsByWindowId[entry.windowId] = pendingTransaction
                }
            }
            return nil
        }

        let transactionId = nextPendingRevealTransactionId
        pendingRevealTransactionsByWindowId[entry.windowId] = PendingRevealTransaction(
            id: transactionId,
            token: entry.token,
            pid: entry.pid,
            windowId: entry.windowId,
            workspaceId: entry.workspaceId,
            plannedSeq: controller.workspaceManager.worldSeq,
            targetFrame: targetFrame,
            targetMonitorId: monitor.id,
            hiddenState: hiddenState,
            postSuccessActions: makePostLayoutAction(
                onSuccess,
                workspaceIds: [entry.workspaceId]
            ).map { [$0] } ?? [],
            revealGroupId: revealGroupId
        )
        if let revealGroupId {
            revealGroups.register(transactionId, groupId: revealGroupId)
        }
        nextPendingRevealTransactionId &+= 1
        return transactionId
    }

    func rekeyPendingRevealTransaction(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        entry: WindowState
    ) {
        let oldWindowId = oldToken.windowId
        let newWindowId = newToken.windowId
        guard oldWindowId != newWindowId || oldToken != newToken else { return }
        guard var transaction = pendingRevealTransactionsByWindowId.removeValue(forKey: oldWindowId) else {
            return
        }

        transaction.token = newToken
        transaction.pid = entry.pid
        transaction.windowId = entry.windowId
        transaction.workspaceId = entry.workspaceId
        if let controller {
            transaction.plannedSeq = controller.workspaceManager.worldSeq
        }
        pendingRevealTransactionsByWindowId[newWindowId] = transaction

        if let verificationTask = pendingRevealVerificationTasksByWindowId.removeValue(forKey: oldWindowId) {
            verificationTask.cancel()
            if transaction.delayedVerificationScheduled {
                scheduleDelayedRevealVerification(forWindowId: newWindowId)
            }
        }
    }

    func refreshPendingRevealTransactionPlannedSeq(
        forWindowId windowId: Int,
        transactionId: UInt64
    ) {
        guard let controller,
              var transaction = pendingRevealTransactionsByWindowId[windowId],
              transaction.id == transactionId
        else {
            return
        }
        transaction.plannedSeq = controller.workspaceManager.worldSeq
        pendingRevealTransactionsByWindowId[windowId] = transaction
    }

    func cancelPendingScratchpadReveal(for token: WindowToken) {
        guard let transaction = pendingRevealTransactionsByWindowId[token.windowId],
              transaction.token == token,
              transaction.hiddenState.isScratchpad
        else {
            return
        }
        if let revealGroupId = transaction.revealGroupId {
            discardScratchpadRevealGroupAndReconcile(revealGroupId)
        }
        pendingRevealTransactionsByWindowId.removeValue(forKey: token.windowId)
        pendingRevealVerificationTasksByWindowId.removeValue(forKey: token.windowId)?.cancel()
        controller?.axManager.cancelPendingFrameJobs(
            [(transaction.pid, transaction.windowId)],
            reason: "scratchpad-reveal-cancelled"
        )
    }

    func completePendingRevealTransaction(
        with result: AXFrameApplyResult,
        transactionId: UInt64
    ) {
        guard let transaction = pendingRevealTransactionsByWindowId[result.windowId],
              transaction.id == transactionId
        else {
            return
        }

        let outcome = hiddenRevealTerminalOutcome(for: result, transaction: transaction)

        switch outcome {
        case .success:
            finalizePendingRevealTransactionSuccess(
                forWindowId: result.windowId,
                confirmedFrame: result.confirmedFrame,
                transactionId: transaction.id
            )
        case .delayedVerification:
            guard var pendingTransaction = pendingRevealTransactionsByWindowId[result.windowId],
                  !pendingTransaction.delayedVerificationScheduled
            else {
                return
            }
            pendingTransaction.delayedVerificationScheduled = true
            pendingRevealTransactionsByWindowId[result.windowId] = pendingTransaction
            scheduleDelayedRevealVerification(forWindowId: result.windowId)
        case .failure:
            finalizePendingRevealTransactionFailure(
                forWindowId: result.windowId,
                transactionId: transaction.id
            )
        }
    }

    func pendingRevealTransactionIsCurrent(
        _ transaction: PendingRevealTransaction,
        using workspaceManager: WorkspaceManager
    ) -> Bool {
        if let revealGroupId = transaction.revealGroupId,
           !revealGroups.contains(revealGroupId)
        {
            return false
        }
        return workspaceManager.isSeqCurrent(
            transaction.plannedSeq,
            for: transaction.workspaceId,
            domains: .layoutCommit
        )
    }

    private func scheduleDelayedRevealVerification(forWindowId windowId: Int) {
        pendingRevealVerificationTasksByWindowId[windowId]?.cancel()
        guard let transactionId = pendingRevealTransactionsByWindowId[windowId]?.id else { return }
        pendingRevealVerificationTasksByWindowId[windowId] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.delayedRevealVerificationDelay)
            } catch {
                return
            }
            guard let self else { return }
            let verifiedFrame = self.delayedVerifiedRevealFrame(
                forWindowId: windowId,
                transactionId: transactionId
            )
            if let verifiedFrame {
                self.finalizePendingRevealTransactionSuccess(
                    forWindowId: windowId,
                    confirmedFrame: verifiedFrame,
                    transactionId: transactionId
                )
            } else {
                self.finalizePendingRevealTransactionFailure(
                    forWindowId: windowId,
                    transactionId: transactionId
                )
            }
        }
    }
}

extension LayoutRefreshController {
    func applyLayoutMutations(_ plan: WorkspaceLayoutPlan, controller: WMController) {
        controller.withRuntimeFrameJobCancellationSuppressed {
            applySessionPatch(plan.sessionPatch)
            diffExecutor.execute(plan)
            controller.workspaceManager.setNiriRestorePlacements(plan.niriRestorePlacements)
            controller.workspaceManager.setDwindleRestorePlacements(plan.dwindleRestorePlacements)
        }
    }
}
