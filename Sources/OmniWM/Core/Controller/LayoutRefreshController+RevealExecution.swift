// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension LayoutRefreshController {
    @discardableResult
    func unhideWindow(
        _ entry: WindowState,
        monitor: Monitor,
        onSuccess: PostLayoutAction? = nil,
        revealGroupId: UInt64? = nil
    ) -> Bool {
        guard let controller else { return false }
        guard let hiddenState = controller.workspaceManager.hiddenState(for: entry.token) else {
            if controller.axManager.pendingParkWindowIds.contains(entry.windowId),
               let frame = fastFrame(for: entry.token, axRef: entry.axRef)
               ?? controller.axManager.lastAppliedFrame(for: entry.windowId)
            {
                applyPositionPlans([WindowPositionPlan(entry: entry, frame: frame)])
            } else {
                controller.axManager.unsuppressFrameWrites([(entry.pid, entry.windowId)])
            }
            return true
        }
        guard hiddenState.workspaceInactive || hiddenState.reason == .quake else { return false }

        return executeHiddenReveal(
            entry,
            monitor: monitor,
            hiddenState: hiddenState,
            onSuccess: onSuccess,
            revealGroupId: revealGroupId
        )
    }

    @discardableResult
    func restoreScratchpadWindow(
        _ entry: WindowState,
        monitor: Monitor,
        onSuccess: PostLayoutAction? = nil,
        revealGroupId: UInt64? = nil
    ) -> Bool {
        guard let controller,
              let hiddenState = controller.workspaceManager.hiddenState(for: entry.token),
              hiddenState.isScratchpad
        else {
            return false
        }

        return executeHiddenReveal(
            entry,
            monitor: monitor,
            hiddenState: hiddenState,
            onSuccess: onSuccess,
            revealGroupId: revealGroupId
        )
    }

    func executeHiddenReveal(
        _ entry: WindowState,
        monitor: Monitor,
        hiddenState: HiddenState,
        onSuccess: PostLayoutAction? = nil,
        revealGroupId: UInt64? = nil
    ) -> Bool {
        guard let controller else { return false }
        let entry = controller.workspaceManager.entry(for: entry.token) ?? entry
        let reveal = HiddenRevealContext(
            entry: entry, monitor: monitor, hiddenState: hiddenState,
            onSuccess: onSuccess, revealGroupId: revealGroupId,
            frameEntry: [(entry.pid, entry.windowId)]
        )
        switch restoreWindowFromHiddenState(entry, monitor: monitor, hiddenState: hiddenState) {
        case .none:
            guard hiddenState.workspaceInactive || hiddenState.reason == .quake else {
                controller.axManager.suppressFrameWrites(reveal.frameEntry)
                return false
            }
            prepareImmediateReveal(reveal, controller: controller)
            completeImmediateReveal(reveal, controller: controller)
            return true
        case let .positionPlan(plan):
            applyPositionPlans([plan])
            prepareImmediateReveal(reveal, controller: controller)
            completeImmediateReveal(reveal, controller: controller)
            return true
        case let .asyncFrame(frame):
            return applyHiddenRevealFrame(frame, reveal: reveal, controller: controller)
        }
    }

    private func prepareImmediateReveal(_ reveal: HiddenRevealContext, controller: WMController) {
        let currentTransactions = reveal.revealGroupId.map {
            currentScratchpadRevealTransactionIds(
                in: $0,
                using: controller.workspaceManager
            )
        } ?? []
        controller.withRuntimeFrameJobCancellationSuppressed {
            controller.workspaceManager.setHiddenState(nil, for: reveal.entry.token)
        }
        rebaseScratchpadRevealTransactions(
            currentTransactions,
            to: controller.workspaceManager.worldSeq
        )
        if reveal.hiddenState.isScratchpad {
            controller.requestWorkspaceBarRefresh()
        }
        controller.axManager.unsuppressFrameWrites(reveal.frameEntry)
    }

    private func completeImmediateReveal(_ reveal: HiddenRevealContext, controller: WMController) {
        if let revealGroupId = reveal.revealGroupId {
            revealGroups.recordSuccess(reveal.entry.token, groupId: revealGroupId)
        } else {
            acceptedPostLayoutAction(
                reveal.onSuccess,
                workspaceIds: [controller.workspaceManager.workspace(for: reveal.entry.token) ?? reveal.entry
                    .workspaceId]
            )?.runIfCurrent(using: controller.workspaceManager)
        }
    }

    private func applyHiddenRevealFrame(
        _ frame: CGRect,
        reveal: HiddenRevealContext,
        controller: WMController
    ) -> Bool {
        if !shouldUsePendingRevealTransaction(for: reveal.entry, hiddenState: reveal.hiddenState) {
            prepareImmediateReveal(reveal, controller: controller)
            controller.axManager.forceApplyNextFrame(for: reveal.entry.windowId)
            controller.axManager.applyFramesParallel([
                .init(pid: reveal.entry.pid, window: reveal.entry.axRef, frame: frame)
            ])
            completeImmediateReveal(reveal, controller: controller)
            return true
        }
        guard let transactionId = beginPendingRevealTransaction(
            for: reveal.entry,
            hiddenState: reveal.hiddenState,
            targetFrame: frame,
            monitor: reveal.monitor,
            onSuccess: reveal.onSuccess,
            revealGroupId: reveal.revealGroupId
        ) else {
            return true
        }
        controller.axManager.unsuppressFrameWrites(reveal.frameEntry)
        controller.axManager.forceApplyNextFrame(for: reveal.entry.windowId)
        controller.axManager.applyFramesParallel(
            [.init(pid: reveal.entry.pid, window: reveal.entry.axRef, frame: frame)],
            terminalObserver: { [weak self] result in
                self?.completePendingRevealTransaction(
                    with: result,
                    transactionId: transactionId
                )
            }
        )
        return true
    }

    private struct HiddenRevealContext {
        let entry: WindowState
        let monitor: Monitor
        let hiddenState: HiddenState
        let onSuccess: PostLayoutAction?
        let revealGroupId: UInt64?
        let frameEntry: [(pid: pid_t, windowId: Int)]
    }
}
