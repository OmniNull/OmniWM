// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

@MainActor
final class LayoutDiffExecutor {
    struct FrameOnlyPreparation {
        let frameUpdates: [AXFrameApplicationTarget]
        let terminalRecoveryFrameUpdates: [AXFrameApplicationTarget]
    }

    private unowned let refreshController: LayoutRefreshController

    init(refreshController: LayoutRefreshController) {
        self.refreshController = refreshController
    }

    static func frameBackedLayoutTransientRestoreFrame(
        hiddenState: HiddenState,
        frameChange: CGRect?
    ) -> CGRect? {
        guard hiddenState.offscreenSide != nil else { return nil }
        return frameChange
    }

    func execute(_ plan: WorkspaceLayoutPlan) {
        guard let controller = refreshController.controller,
              let monitor = resolveMonitor(from: plan.monitor, controller: controller)
        else { return }
        if Self.isFrameOnly(plan.diff) {
            executeFrameOnly(plan.diff, plan: plan, monitor: monitor, controller: controller)
            return
        }
        var application = LayoutVisibilityApplication(
            plan: plan, monitor: monitor, controller: controller, refreshController: refreshController
        )
        application.execute()
    }

    nonisolated static func isFrameOnly(_ diff: WorkspaceLayoutDiff) -> Bool {
        diff.visibilityChanges.isEmpty &&
            diff.restoreChanges.isEmpty &&
            diff.deferredHides.isEmpty
    }

    func prepareFrameOnlyUpdates(
        _ changes: [LayoutFrameChange],
        controller: WMController
    ) -> FrameOnlyPreparation {
        var frameUpdates: [AXFrameApplicationTarget] = []
        frameUpdates.reserveCapacity(changes.count)
        var terminalRecoveryFrameUpdates: [AXFrameApplicationTarget] = []

        for change in changes {
            guard let entry = controller.workspaceManager.entry(for: change.token),
                  entry.layoutReason != .nativeFullscreen
            else {
                continue
            }
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

        return FrameOnlyPreparation(
            frameUpdates: frameUpdates,
            terminalRecoveryFrameUpdates: terminalRecoveryFrameUpdates
        )
    }

    private func executeFrameOnly(
        _ diff: WorkspaceLayoutDiff,
        plan: WorkspaceLayoutPlan,
        monitor: Monitor,
        controller: WMController
    ) {
        let preparation = prepareFrameOnlyUpdates(diff.frameChanges, controller: controller)
        Self.applyFrameUpdates(
            preparation.frameUpdates,
            isAnimationTick: plan.isAnimationTick,
            isInteractiveResize: plan.isInteractiveResize,
            controller: controller
        )
        refreshController.applyWorkspaceMonitorRelocationFrameUpdates(
            preparation.terminalRecoveryFrameUpdates,
            workspaceId: plan.workspaceId,
            monitorId: monitor.id,
            controller: controller
        )
    }

    static func applyFrameUpdates(
        _ frameUpdates: [AXFrameApplicationTarget],
        isAnimationTick: Bool,
        isInteractiveResize: Bool = false,
        controller: WMController
    ) {
        guard !frameUpdates.isEmpty else { return }
        let axManager = controller.axManager
        if !isAnimationTick {
            for update in frameUpdates where axManager.skyLightLivePosition(for: update.windowId) != nil {
                axManager.forceApplyNextFrame(for: update.windowId)
            }
        }
        guard isInteractiveResize else {
            axManager.applyFramesParallel(frameUpdates, verify: !isAnimationTick)
            return
        }
        let moves = frameUpdates.filter { $0.components == .position }
        axManager.applyFramesParallel(moves, verify: false)
        axManager.applyFramesParallel(frameUpdates.filter { $0.components != .position })
    }

    private func resolveMonitor(
        from snapshot: LayoutMonitorSnapshot,
        controller: WMController
    ) -> Monitor? {
        if let monitor = controller.workspaceManager.monitor(byId: snapshot.monitorId) {
            return monitor
        }

        return controller.workspaceManager.monitors.first(where: { $0.displayId == snapshot.displayId })
    }
}
