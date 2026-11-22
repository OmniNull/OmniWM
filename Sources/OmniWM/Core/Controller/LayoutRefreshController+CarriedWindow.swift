// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension LayoutRefreshController {
    struct CarriedWindowDrawStamp: Equatable {
        let workspaceId: WorkspaceDescriptor.ID
        let worldSeq: UInt64
        let displayId: CGDirectDisplayID
        let workingFrame: CGRect
    }

    func renderCarriedWindow(
        _ token: WindowToken, frame: CGRect, engine: NiriLayoutEngine, monitor: Monitor, context: NiriInteractionContext
    ) {
        guard let controller else { return }
        let workspaceId = context.workspaceId
        let manager = controller.workspaceManager
        let state = manager.niriViewportState(for: workspaceId)
        func drawOwner() -> CarriedWindowRefresh {
            carriedWindowDrawOwner(
                for: token, in: (workspaceId, monitor.id), state: state, engine: engine, controller: controller
            )
        }
        let owner = drawOwner()
        if owner == .ownsFrame {
            carriedWindowDrawStamp = nil
            return
        }

        let stamp = CarriedWindowDrawStamp(
            workspaceId: workspaceId, worldSeq: manager.worldSeq,
            displayId: monitor.displayId, workingFrame: context.workingFrame
        )
        let idle = owner == .idle
        if idle, carriedWindowDrawStamp == stamp {
            let change = niriHandler.settledFrameChange(
                token: token, frame: frame, node: engine.states[workspaceId]?.nodesByToken[token],
                workspace: (workspaceId, engine),
                horizontalEdge: context.orientation == .horizontal ? (monitor.frame, state) : nil
            )
            applyCarriedWindowFrame(
                change,
                in: workspaceId,
                isVertical: context.orientation == .vertical,
                controller: controller
            )
            return
        }

        carriedWindowDrawStamp = nil
        let applied = niriHandler.applyFramesOnDemand(
            wsId: workspaceId, state: state, engine: engine, monitor: monitor, isInteractiveMove: true,
            requiringSettledFrameFor: idle ? token : nil
        )
        if applied, idle, stamp.worldSeq == manager.worldSeq, drawOwner() == .idle {
            carriedWindowDrawStamp = stamp
        }
    }

    func renderDwindleCarriedWindow(
        in workspaceId: WorkspaceDescriptor.ID,
        on monitor: Monitor,
        geometry: LayoutMonitorSnapshot,
        controller: WMController
    ) {
        guard !hasDwindleAnimationRunning(in: workspaceId),
              carriedWindowRefresh(for: workspaceId, on: monitor.id, manager: controller.workspaceManager) != .ownsFrame
        else { return }
        dwindleHandler.applyFramesOnDemand(
            workspaceId: workspaceId, monitor: monitor, isInteractiveMove: true,
            activeMonitor: (workspaceId, geometry)
        )
    }

    fileprivate enum CarriedWindowRefresh {
        case idle, otherWork, ownsFrame
    }

    private func carriedWindowRefresh(
        for workspaceId: WorkspaceDescriptor.ID, on monitorId: Monitor.ID, manager: WorkspaceManager
    ) -> CarriedWindowRefresh {
        let queued = layoutState.pendingRefresh?.carriedWindowRefresh(for: workspaceId, on: monitorId, manager: manager)
            ?? .idle
        guard queued != .ownsFrame, !layoutState.didExecuteEffectPlan else { return queued }
        let active = layoutState.activeRefresh?.carriedWindowRefresh(for: workspaceId, on: monitorId, manager: manager)
            ?? .idle
        return active == .idle ? queued : active
    }

    private func carriedWindowDrawOwner(
        for token: WindowToken, in workspace: (id: WorkspaceDescriptor.ID, monitor: Monitor.ID),
        state: ViewportState, engine: NiriLayoutEngine, controller: WMController
    ) -> CarriedWindowRefresh {
        let workspaceId = workspace.id
        let manager = controller.workspaceManager
        let refresh = carriedWindowRefresh(for: workspaceId, on: workspace.monitor, manager: manager)
        if niriHandler.hasScrollAnimation(for: workspaceId) { return .ownsFrame }
        guard refresh == .idle else { return refresh }
        let ax = controller.axManager
        func isInWorkspace(_ windowId: Int) -> Bool {
            manager.withEntry(forWindowId: windowId) { $0.workspaceId == workspaceId } == true
        }
        if controller.niriEdgePictures.requiresFullCarryDraw(in: workspaceId)
            || ax.pendingParkWindowIds.contains(where: isInWorkspace)
            || ax.frameLedger.forceApplyWindowIds.contains(where: { $0 != token.windowId && isInWorkspace($0) })
            || nativeFullscreenRestoredFrameApplyTokens.contains(where: { manager.workspace(for: $0) == workspaceId })
            || hasPendingNiriAnimationWork(
                state: state, driver: manager.animationDriver, engine: engine, workspaceId: workspaceId
            )
        {
            return .otherWork
        }
        return .idle
    }

    private func applyCarriedWindowFrame(
        _ change: LayoutFrameChange, in workspaceId: WorkspaceDescriptor.ID, isVertical: Bool, controller: WMController
    ) {
        controller.withRuntimeFrameJobCancellationSuppressed {
            let enforced = controller.axManager.enforcedSizeFrameChange(change)
            if isVertical { controller.niriEdgePictures.updatePendingCapture(for: enforced, in: workspaceId) }
            let prepared = diffExecutor.prepareFrameOnlyUpdates([enforced], controller: controller)
            LayoutDiffExecutor.applyFrameUpdates(prepared.frameUpdates, isAnimationTick: false, controller: controller)
            if !controller.shellAppWindowManager.windows.isEmpty {
                controller.shellAppWindowManager.reconcileAttachedGeometry(in: workspaceId)
            }
        }
        niriHandler.followOverflowMessage(in: workspaceId)
        niriHandler.scheduleOverflowCheck()
        controller.surfaceReconciler.noteInvalidation(.layoutEdge)
    }
}

extension LayoutRefreshController.ScheduledRefresh {
    @MainActor fileprivate func carriedWindowRefresh(
        for workspaceId: WorkspaceDescriptor.ID, on monitorId: Monitor.ID, manager: WorkspaceManager
    ) -> LayoutRefreshController.CarriedWindowRefresh {
        guard affectedWorkspaceIds.contains(workspaceId) || additionalAffectedWorkspaceIds.contains(workspaceId)
            || (affectedWorkspaceIds.isEmpty && manager.activeWorkspaceOrFirst(on: monitorId)?.id == workspaceId)
        else { return .idle }
        switch kind {
        case .immediateRelayout,
             .relayout: return .ownsFrame
        default: return .otherWork
        }
    }
}
