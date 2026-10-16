// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
struct LayoutVisibilityApplication {
    private let plan: WorkspaceLayoutPlan
    private let monitor: Monitor
    private let controller: WMController
    private let refreshController: LayoutRefreshController
    private let diff: WorkspaceLayoutDiff

    private var resolvedEntries: [WindowToken: WindowState] = [:]
    private var hiddenEntries: [(entry: WindowState, side: HideSide)] = []
    private var hiddenTokens: Set<WindowToken> = []
    private var shownEntries: [(entry: WindowState, hiddenState: HiddenState?)] = []
    private var restoreEntries: [(entry: WindowState, hiddenState: HiddenState)] = []
    private var restoreTokens: Set<WindowToken> = []
    private var frameChangeByToken: [WindowToken: CGRect] = [:]
    private var pendingRevealTransactionIdsByToken: [WindowToken: UInt64] = [:]
    private var blockedRevealTokens: Set<WindowToken> = []

    private var deferredVisibleAXTokens: Set<WindowToken> = []
    private var frameUpdates: [AXFrameApplicationTarget] = []
    private var terminalRecoveryFrameUpdates: [AXFrameApplicationTarget] = []
    private var revealFrameUpdates: [(target: AXFrameApplicationTarget, transactionId: UInt64)] = []
    private var deferredRevealFrameUpdates: [DeferredRevealFrameUpdate] = []
    private struct DeferredRevealFrameUpdate {
        let pid: pid_t
        let windowId: Int
        let frame: CGRect
        let token: WindowToken
    }

    init(
        plan: WorkspaceLayoutPlan,
        monitor: Monitor,
        controller: WMController,
        refreshController: LayoutRefreshController
    ) {
        self.plan = plan
        diff = plan.diff
        self.monitor = monitor
        self.controller = controller
        self.refreshController = refreshController
    }

    mutating func execute() {
        prepareVisibility()
        prepareRestores()
        beginReveals()
        refreshController.applyLayoutTransientHides(
            hiddenEntries, monitor: monitor, isAnimationTick: plan.isAnimationTick,
            preserveWorkspaceInactive: !plan.isActiveWorkspace
        )
        restoreHiddenEntries()
        clearShownHiddenStates()
        unsuppressVisibleWindows()
        prepareFrames()
        applyFrames()
    }

    private mutating func prepareVisibility() {
        for change in diff.frameChanges {
            frameChangeByToken[change.token] = change.frame
        }

        for change in diff.visibilityChanges {
            switch change {
            case let .show(token):
                guard let entry = resolveEntry(for: token) else { continue }
                guard entry.layoutReason != .nativeFullscreen else { continue }
                shownEntries.append((entry, controller.workspaceManager.hiddenState(for: token)))
            case let .hide(token, side):
                hiddenTokens.insert(token)
                guard let entry = resolveEntry(for: token) else { continue }
                guard entry.layoutReason != .nativeFullscreen else { continue }
                hiddenEntries.append((entry, side))
            }
        }

        for change in diff.deferredHides {
            hiddenTokens.insert(change.token)
        }
    }

    private mutating func prepareRestores() {
        for restoreChange in diff.restoreChanges where !hiddenTokens.contains(restoreChange.token) {
            guard restoreTokens.insert(restoreChange.token).inserted,
                  let entry = resolveEntry(for: restoreChange.token)
            else {
                continue
            }
            guard entry.layoutReason != .nativeFullscreen else { continue }
            restoreEntries.append((entry, restoreChange.hiddenState))
        }

        for (entry, hiddenState) in shownEntries
            where !hiddenTokens.contains(entry.token) && !isDeferredReveal(entry.token)
        {
            guard let hiddenState, restoreTokens.insert(entry.token).inserted else { continue }
            restoreEntries.append((entry, hiddenState))
        }
    }

    private mutating func beginReveals() {
        for (entry, hiddenState) in restoreEntries {
            beginReveal(entry, hiddenState: hiddenState)
        }
        for (entry, hiddenState) in shownEntries where !restoreTokens.contains(entry.token) {
            guard let hiddenState else { continue }
            beginReveal(entry, hiddenState: hiddenState)
        }
    }

    private mutating func beginReveal(_ entry: WindowState, hiddenState: HiddenState) {
        guard refreshController.shouldUsePendingRevealTransaction(
            for: entry,
            hiddenState: hiddenState
        ) else {
            return
        }
        if let targetFrame = frameChangeByToken[entry.token] {
            if let transactionId = refreshController.beginPendingRevealTransaction(
                for: entry,
                hiddenState: hiddenState,
                targetFrame: targetFrame,
                monitor: monitor
            ) {
                pendingRevealTransactionIdsByToken[entry.token] = transactionId
            } else {
                blockedRevealTokens.insert(entry.token)
            }
        } else if refreshController.hasPendingRevealTransaction(for: entry.windowId) {
            blockedRevealTokens.insert(entry.token)
        }
    }

    private mutating func restoreHiddenEntries() {
        if !restoreEntries.isEmpty {
            var frameBackedLayoutTransientTokens: Set<WindowToken> = []
            frameBackedLayoutTransientTokens.reserveCapacity(restoreEntries.count)
            let restorePlans: [LayoutRefreshController.WindowPositionPlan] = restoreEntries
                .compactMap { entry, hiddenState in
                    guard !blockedRevealTokens.contains(entry.token),
                          pendingRevealTransactionIdsByToken[entry.token] == nil
                    else { return nil }
                    if let plannedFrame = LayoutDiffExecutor.frameBackedLayoutTransientRestoreFrame(
                        hiddenState: hiddenState,
                        frameChange: frameChangeByToken[entry.token]
                    ) {
                        frameBackedLayoutTransientTokens.insert(entry.token)
                        return LayoutRefreshController.WindowPositionPlan(
                            entry: entry,
                            frame: plannedFrame
                        )
                    }
                    return refreshController.makeRestorePositionPlan(
                        for: entry,
                        monitor: monitor,
                        hiddenState: hiddenState
                    )
                }
            deferredVisibleAXTokens = refreshController.applyPositionPlans(
                restorePlans,
                deferringVisibleAXFor: frameBackedLayoutTransientTokens
            )

            for (entry, _) in restoreEntries
                where pendingRevealTransactionIdsByToken[entry.token] == nil
                && !blockedRevealTokens.contains(entry.token)
            {
                controller.workspaceManager.setHiddenState(nil, for: entry.token)
            }
        }
    }

    private func clearShownHiddenStates() {
        if !shownEntries.isEmpty {
            for (entry, _) in shownEntries
                where !restoreTokens.contains(entry.token)
                && pendingRevealTransactionIdsByToken[entry.token] == nil
                && !blockedRevealTokens.contains(entry.token)
                && !isDeferredReveal(entry.token)
            {
                controller.workspaceManager.setHiddenState(nil, for: entry.token)
            }
        }
    }

    private func unsuppressVisibleWindows() {
        if !restoreEntries.isEmpty || !shownEntries.isEmpty {
            var visibleJobs: [(pid: pid_t, windowId: Int)] = []
            visibleJobs.reserveCapacity(restoreEntries.count + shownEntries.count)
            var seenTokens: Set<WindowToken> = []

            for (entry, _) in restoreEntries
                where !blockedRevealTokens.contains(entry.token)
                && seenTokens.insert(entry.token).inserted
            {
                visibleJobs.append((entry.pid, entry.windowId))
            }

            for (entry, _) in shownEntries
                where !blockedRevealTokens.contains(entry.token)
                && seenTokens.insert(entry.token).inserted
            {
                visibleJobs.append((entry.pid, entry.windowId))
            }

            if !visibleJobs.isEmpty {
                controller.axManager.unsuppressFrameWrites(visibleJobs)
            }
        }
    }

    private mutating func resolveEntry(for token: WindowToken) -> WindowState? {
        if let cached = resolvedEntries[token] {
            return cached
        }
        guard let entry = controller.workspaceManager.entry(for: token) else {
            return nil
        }
        resolvedEntries[token] = entry
        return entry
    }

    private func isDeferredReveal(_ token: WindowToken) -> Bool {
        diff.deferredHides.contains { $0.revealToken == token }
    }
}

extension LayoutVisibilityApplication {
    private mutating func prepareFrames() {
        frameUpdates.reserveCapacity(diff.frameChanges.count)
        revealFrameUpdates.reserveCapacity(pendingRevealTransactionIdsByToken.count)
        deferredRevealFrameUpdates.reserveCapacity(diff.deferredHides.count)

        for change in diff.frameChanges {
            guard !hiddenTokens.contains(change.token),
                  let entry = resolveEntry(for: change.token),
                  !blockedRevealTokens.contains(change.token)
            else {
                continue
            }
            guard entry.layoutReason != .nativeFullscreen else { continue }
            if deferredVisibleAXTokens.contains(change.token) {
                controller.axManager.markWindowActive(entry.windowId)
                controller.axManager.forceApplyNextFrame(for: entry.windowId)
            }
            if pendingRevealTransactionIdsByToken[change.token] != nil {
                controller.axManager.forceApplyNextFrame(for: entry.windowId)
            }
            if let transactionId = pendingRevealTransactionIdsByToken[change.token] {
                revealFrameUpdates.append((
                    target: AXFrameApplicationTarget(pid: entry.pid, window: entry.axRef, frame: change.frame),
                    transactionId: transactionId
                ))
            } else {
                if isDeferredReveal(change.token) {
                    controller.axManager.forceApplyNextFrame(for: entry.windowId)
                    deferredRevealFrameUpdates.append(
                        DeferredRevealFrameUpdate(
                            pid: entry.pid,
                            windowId: entry.windowId,
                            frame: change.frame,
                            token: change.token
                        )
                    )
                    continue
                }
                prepareOrdinaryFrame(change, entry: entry)
            }
        }
    }

    private mutating func prepareOrdinaryFrame(_ change: LayoutFrameChange, entry: WindowState) {
        let forceNativeFullscreenRestoreApply = refreshController
            .consumeNativeFullscreenRestoredFrameApply(for: change.token)
        if change.forceApply {
            controller.axManager.forceApplyNextFrame(for: entry.windowId)
        }
        if forceNativeFullscreenRestoreApply {
            controller.axManager.forceApplyNextFrame(for: entry.windowId)
        }
        let frameUpdate = AXFrameApplicationTarget(
            pid: entry.pid,
            window: entry.axRef,
            frame: change.frame,
            components: change.components
        )
        if change.allowsTerminalRecovery {
            terminalRecoveryFrameUpdates.append(frameUpdate)
        } else {
            frameUpdates.append(frameUpdate)
        }
    }

    private func applyFrames() {
        LayoutDiffExecutor.applyFrameUpdates(
            frameUpdates,
            isAnimationTick: plan.isAnimationTick,
            isInteractiveResize: plan.isInteractiveResize,
            controller: controller
        )
        refreshController.applyWorkspaceMonitorRelocationFrameUpdates(
            terminalRecoveryFrameUpdates,
            workspaceId: plan.workspaceId,
            monitorId: monitor.id,
            controller: controller
        )

        applyDeferredRevealFrames()
        applyRevealFrames()
    }

    private func applyRevealFrames() {
        if !revealFrameUpdates.isEmpty {
            var revealTransactionIdsByWindowId: [Int: UInt64] = [:]
            revealTransactionIdsByWindowId.reserveCapacity(revealFrameUpdates.count)
            for update in revealFrameUpdates {
                refreshController.refreshPendingRevealTransactionPlannedSeq(
                    forWindowId: update.target.windowId,
                    transactionId: update.transactionId
                )
                revealTransactionIdsByWindowId[update.target.windowId] = update.transactionId
            }
            controller.axManager.applyFramesParallel(
                revealFrameUpdates.map(\.target),
                terminalObserver: { [weak refreshController, revealTransactionIdsByWindowId] result in
                    guard let refreshController,
                          let transactionId = revealTransactionIdsByWindowId[result.windowId]
                          ?? refreshController.pendingRevealTransactionId(forWindowId: result.windowId)
                    else {
                        return
                    }
                    refreshController.completePendingRevealTransaction(
                        with: result,
                        transactionId: transactionId
                    )
                }
            )
        }
    }

    private func applyDeferredRevealFrames() {
        guard !deferredRevealFrameUpdates.isEmpty else { return }
        for update in deferredRevealFrameUpdates {
            guard let entry = controller.workspaceManager.entry(for: update.token),
                  let transactionId = refreshController.dwindleHandler.groupReveals.beginPendingGroupRevealTransaction(
                      for: entry,
                      targetFrame: update.frame,
                      monitor: monitor,
                      hides: diff.deferredHides.filter { $0.revealToken == update.token },
                      preserveWorkspaceInactive: !plan.isActiveWorkspace
                  )
            else {
                continue
            }
            controller.axManager.applyFramesParallel(
                [.init(pid: entry.pid, window: entry.axRef, frame: update.frame)],
                terminalObserver: { [weak refreshController] result in
                    refreshController?.dwindleHandler.groupReveals.completePendingGroupRevealTransaction(
                        with: result,
                        transactionId: transactionId
                    )
                }
            )
        }
    }
}
