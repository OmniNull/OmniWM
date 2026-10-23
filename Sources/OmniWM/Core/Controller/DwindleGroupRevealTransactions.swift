// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

@MainActor
final class DwindleGroupRevealTransactions {
    private weak var handler: DwindleLayoutHandler?
    private var controller: WMController? {
        handler?.controller
    }

    private struct PendingGroupRevealTransaction {
        let id: UInt64
        var token: WindowToken
        var pid: pid_t
        var windowId: Int
        var workspaceId: WorkspaceDescriptor.ID
        let tileId: DwindleTileId
        let targetFrame: CGRect
        let targetMonitorId: Monitor.ID
        var hides: [LayoutDeferredHide]
        let preserveWorkspaceInactive: Bool
        var refreshOverviewOnSuccess: Bool
        var focusOriginOnSuccess: ManagedFocusOrigin?
        var focusPlannedSeq: UInt64?
    }

    private var nextPendingGroupRevealTransactionId: UInt64 = 1
    private var pendingGroupRevealTransactionsByWindowId: [Int: PendingGroupRevealTransaction] = [:]

    init(handler: DwindleLayoutHandler) {
        self.handler = handler
    }

    func beginPendingGroupRevealTransaction(
        for entry: WindowState,
        targetFrame: CGRect,
        monitor: Monitor,
        hides: [LayoutDeferredHide],
        preserveWorkspaceInactive: Bool
    ) -> UInt64? {
        guard let controller,
              let engine = controller.dwindleEngine,
              let tile = engine.tileSnapshot(for: entry.token, in: entry.workspaceId),
              tile.activeToken == entry.token,
              !hides.isEmpty
        else {
            return nil
        }

        let transactionId = nextPendingGroupRevealTransactionId
        nextPendingGroupRevealTransactionId &+= 1
        let existingTransaction = pendingGroupRevealTransactionsByWindowId[entry.windowId]
        pendingGroupRevealTransactionsByWindowId[entry.windowId] = .init(
            id: transactionId,
            token: entry.token,
            pid: entry.pid,
            windowId: entry.windowId,
            workspaceId: entry.workspaceId,
            tileId: tile.id,
            targetFrame: targetFrame,
            targetMonitorId: monitor.id,
            hides: hides,
            preserveWorkspaceInactive: preserveWorkspaceInactive,
            refreshOverviewOnSuccess: existingTransaction?.refreshOverviewOnSuccess ?? false,
            focusOriginOnSuccess: existingTransaction?.focusOriginOnSuccess,
            focusPlannedSeq: existingTransaction?.focusPlannedSeq
        )
        return transactionId
    }

    func deferGroupSelectionCompletion(
        _ token: WindowToken,
        workspaceId: WorkspaceDescriptor.ID,
        focusAfterReveal: Bool,
        focusOrigin: ManagedFocusOrigin
    ) -> Bool {
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token),
              entry.workspaceId == workspaceId,
              var transaction = pendingGroupRevealTransactionsByWindowId[entry.windowId],
              transaction.token == token,
              transaction.workspaceId == workspaceId
        else {
            return false
        }

        transaction.refreshOverviewOnSuccess = true
        if focusAfterReveal {
            transaction.focusOriginOnSuccess = transaction.focusOriginOnSuccess?
                .merged(with: focusOrigin) ?? focusOrigin
            transaction.focusPlannedSeq = controller.workspaceManager.worldSeq
        }
        pendingGroupRevealTransactionsByWindowId[entry.windowId] = transaction
        return true
    }

    func completePendingGroupRevealTransaction(
        with result: AXFrameApplyResult,
        transactionId: UInt64
    ) {
        guard let transactionKey = pendingGroupRevealTransactionKey(
                  for: result.windowId,
                  transactionId: transactionId
              ),
              let transaction = pendingGroupRevealTransactionsByWindowId.removeValue(
                  forKey: transactionKey
              ),
              transaction.targetFrame.approximatelyEqual(
                  to: result.targetFrame,
                  tolerance: FrameTolerance.frameWrite
              )
        else {
            return
        }

        guard result.writeResult.isVerifiedSuccess else {
            rollbackPendingGroupReveal(transaction)
            return
        }
        finalizePendingGroupReveal(transaction)
    }

    func pendingGroupRevealTransactionId(for windowId: Int) -> UInt64? {
        pendingGroupRevealTransactionsByWindowId[windowId]?.id
    }

    func resetPendingGroupReveals() {
        pendingGroupRevealTransactionsByWindowId.removeAll()
        nextPendingGroupRevealTransactionId = 1
    }

    func cancelPendingGroupReveals(pid: pid_t) {
        pendingGroupRevealTransactionsByWindowId = pendingGroupRevealTransactionsByWindowId.filter {
            $0.value.pid != pid
        }
    }

    func cancelPendingGroupReveal(for token: WindowToken) {
        guard pendingGroupRevealTransactionsByWindowId[token.windowId]?.pid == token.pid else { return }
        pendingGroupRevealTransactionsByWindowId.removeValue(forKey: token.windowId)
    }

    func currentPendingGroupRevealFocusTransactionIds(
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Set<UInt64> {
        guard let controller else { return [] }
        var transactionIds: Set<UInt64> = []
        for transaction in pendingGroupRevealTransactionsByWindowId.values
            where transaction.workspaceId == workspaceId
        {
            guard let plannedSeq = transaction.focusPlannedSeq,
                  controller.workspaceManager.isSeqCurrent(
                      plannedSeq,
                      for: workspaceId,
                      domains: .focusCommit
                  )
            else {
                continue
            }
            transactionIds.insert(transaction.id)
        }
        return transactionIds
    }

    func currentPendingGroupRevealFocusTransactionIds(for token: WindowToken) -> Set<UInt64> {
        guard let workspaceId = controller?.workspaceManager.entry(for: token)?.workspaceId else { return [] }
        return currentPendingGroupRevealFocusTransactionIds(in: workspaceId)
    }

    func rekeyPendingGroupRevealTransaction(
        from oldToken: WindowToken,
        to newToken: WindowToken,
        entry: WindowState,
        rebasingFocusTransactionIds: Set<UInt64>
    ) {
        guard oldToken != newToken else { return }
        let keys = Array(pendingGroupRevealTransactionsByWindowId.keys)
        for key in keys {
            guard var transaction = pendingGroupRevealTransactionsByWindowId.removeValue(forKey: key)
            else {
                continue
            }
            let transactionKey: Int
            if transaction.token == oldToken {
                transaction.token = newToken
                transaction.pid = entry.pid
                transaction.windowId = entry.windowId
                transaction.workspaceId = entry.workspaceId
                transactionKey = entry.windowId
            } else {
                transactionKey = key
            }
            transaction.hides = transaction.hides.map { change in
                LayoutDeferredHide(
                    token: change.token == oldToken ? newToken : change.token,
                    side: change.side,
                    revealToken: change.revealToken == oldToken ? newToken : change.revealToken
                )
            }
            if rebasingFocusTransactionIds.contains(transaction.id), let controller {
                transaction.focusPlannedSeq = controller.workspaceManager.worldSeq
            }
            if let existing = pendingGroupRevealTransactionsByWindowId[transactionKey],
               existing.id > transaction.id
            {
                continue
            }
            pendingGroupRevealTransactionsByWindowId[transactionKey] = transaction
        }
    }

    private func pendingGroupRevealTransactionKey(
        for windowId: Int,
        transactionId: UInt64
    ) -> Int? {
        if pendingGroupRevealTransactionsByWindowId[windowId]?.id == transactionId {
            return windowId
        }
        return pendingGroupRevealTransactionsByWindowId.first {
            $0.value.id == transactionId
        }?.key
    }
}

extension DwindleGroupRevealTransactions {
    private func finalizePendingGroupReveal(
        _ transaction: PendingGroupRevealTransaction
    ) {
        guard let controller,
              controller.workspaceManager.activeLayoutKind(for: transaction.workspaceId) == .dwindle,
              controller.workspaceManager.visibleWorkspaceIds().contains(transaction.workspaceId),
              let engine = controller.dwindleEngine,
              let revealTile = engine.tileSnapshot(for: transaction.token, in: transaction.workspaceId),
              revealTile.id == transaction.tileId,
              revealTile.activeToken == transaction.token,
              let revealEntry = controller.workspaceManager.entry(for: transaction.token),
              revealEntry.workspaceId == transaction.workspaceId,
              revealEntry.layoutReason == .standard,
              !controller.workspaceManager.isWindowSuppressedByMacOS(revealEntry.token)
        else {
            return
        }

        let shouldFocusAfterReveal = transaction.focusOriginOnSuccess != nil
            && transaction.focusPlannedSeq.map {
                controller.workspaceManager.isSeqCurrent(
                    $0,
                    for: transaction.workspaceId,
                    domains: .focusCommit
                )
            } == true
        let hiddenEntries = deferredHides(
            for: transaction,
            engine: engine,
            revealTileId: revealTile.id,
            controller: controller
        )

        let monitor = controller.workspaceManager.monitor(byId: transaction.targetMonitorId)
            ?? controller.workspaceManager.monitor(for: transaction.workspaceId)
            ?? Monitor.fallback()
        controller.withRuntimeFrameJobCancellationSuppressed {
            controller.workspaceManager.setHiddenState(nil, for: transaction.token)
            controller.layoutRefreshController.applyLayoutTransientHides(
                hiddenEntries,
                monitor: monitor,
                isAnimationTick: false,
                preserveWorkspaceInactive: transaction.preserveWorkspaceInactive
            )
        }
        controller.axManager.clearParkPending(for: transaction.windowId, pid: transaction.pid)
        publishRevealSuccess(transaction, controller: controller, shouldFocusAfterReveal: shouldFocusAfterReveal)
    }

    private func publishRevealSuccess(
        _ transaction: PendingGroupRevealTransaction,
        controller: WMController,
        shouldFocusAfterReveal: Bool
    ) {
        controller.surfaceReconciler.noteWorldChanged()
        if transaction.refreshOverviewOnSuccess {
            controller.windowActionHandler.refreshOverviewProjection(
                affectedWorkspaceIds: [transaction.workspaceId],
                selectedToken: transaction.token
            )
        }
        if shouldFocusAfterReveal, let focusOrigin = transaction.focusOriginOnSuccess {
            controller.focusWindow(transaction.token, origin: focusOrigin)
        }
    }

    private func deferredHides(
        for transaction: PendingGroupRevealTransaction,
        engine: DwindleLayoutEngine,
        revealTileId: DwindleTileId,
        controller: WMController
    ) -> [(entry: WindowState, side: HideSide)] {
        var hiddenEntries: [(entry: WindowState, side: HideSide)] = []
        hiddenEntries.reserveCapacity(transaction.hides.count)
        for change in transaction.hides {
            guard engine.isInactiveGroupMember(change.token, in: transaction.workspaceId),
                  engine.tileSnapshot(for: change.token, in: transaction.workspaceId)?.id == revealTileId,
                  let entry = controller.workspaceManager.entry(for: change.token),
                  entry.workspaceId == transaction.workspaceId,
                  entry.layoutReason != .nativeFullscreen,
                  !controller.workspaceManager.isWindowSuppressedByMacOS(entry.token)
            else {
                continue
            }
            hiddenEntries.append((entry, change.side))
        }

        return hiddenEntries
    }

    private func rollbackPendingGroupReveal(
        _ transaction: PendingGroupRevealTransaction
    ) {
        guard let controller,
              controller.workspaceManager.activeLayoutKind(for: transaction.workspaceId) == .dwindle,
              controller.workspaceManager.visibleWorkspaceIds().contains(transaction.workspaceId),
              let engine = controller.dwindleEngine,
              let revealTile = engine.tileSnapshot(for: transaction.token, in: transaction.workspaceId),
              revealTile.id == transaction.tileId,
              revealTile.activeToken == transaction.token,
              let rollbackToken = transaction.hides.lazy.map(\.token).first(where: {
                  engine.tileSnapshot(for: $0, in: transaction.workspaceId)?.id == transaction.tileId
                      && controller.workspaceManager.entry(for: $0)?.layoutReason == .standard
                      && !controller.workspaceManager.isWindowSuppressedByMacOS($0)
              })
        else {
            return
        }

        let outcome = controller.workspaceManager.withEngineMutationScope {
            engine.activateWindowOutcome(rollbackToken, in: transaction.workspaceId)
        }
        guard outcome == .activated else { return }
        _ = controller.workspaceManager.applySessionPatch(
            .init(
                workspaceId: transaction.workspaceId,
                viewportState: nil,
                rememberedFocusToken: rollbackToken,
                plannedSeq: controller.workspaceManager.worldSeq
            )
        )
        controller.windowActionHandler.refreshOverviewProjection(
            affectedWorkspaceIds: [transaction.workspaceId],
            selectedToken: rollbackToken
        )
        controller.layoutRefreshController.requestLayoutCommandRelayout(
            affectedWorkspaceIds: [transaction.workspaceId]
        )
    }
}
