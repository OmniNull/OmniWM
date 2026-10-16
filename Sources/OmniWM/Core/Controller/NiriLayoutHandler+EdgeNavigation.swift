// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension NiriLayoutHandler {
    @discardableResult
    func focusAdjacentColumn(
        step: Int,
        in workspaceId: WorkspaceDescriptor.ID,
        on monitor: Monitor
    ) -> Bool {
        guard step == -1 || step == 1,
              let controller,
              let engine = controller.niriEngine,
              controller.workspaceManager.activeWorkspace(on: monitor.id)?.id == workspaceId,
              controller.workspaceManager.activeLayoutKind(for: workspaceId) == .niri,
              !controller.workspaceManager.animationDriver.trackpadGestureActive(in: workspaceId)
        else { return false }

        let manager = controller.workspaceManager
        let columns = engine.projectedColumns(in: workspaceId)
        let targetIndex = engine.projectedActiveColumnIndex(
            state: manager.niriViewportState(for: workspaceId),
            columns: columns,
            in: workspaceId
        ) + step
        guard columns.indices.contains(targetIndex) else { return false }

        let geometry = controller.niriInteractionGeometry(for: monitor)
        let context = NiriInteractionContext(
            workspaceId: workspaceId, motion: controller.motionPolicy.snapshot(),
            workingFrame: geometry.workingFrame, gaps: geometry.innerGap,
            orientation: resolvedOrientation(for: workspaceId, monitor: monitor, engine: engine)
        )
        var didAdvance = false
        var shouldStartAnimation = false
        manager.withNiriViewportState(for: workspaceId) { state in
            guard let current = engine.projectedSelectedWindow(state: state, in: workspaceId),
                  let target = engine.focusColumn(
                      targetIndex,
                      currentSelection: current,
                      context: context,
                      state: &state
                  )
            else { return }
            activateNode(
                target,
                in: workspaceId,
                state: &state,
                options: .init(
                    ensureVisible: false, layoutRefresh: false, axFocus: false, startAnimation: false
                )
            )
            didAdvance = true
            shouldStartAnimation = state.hasPendingOffsetAnimation
        }
        guard didAdvance else { return false }
        focusSelectedWindowAndRequestRelayout(in: workspaceId, raisesWindow: false, defersRetryRaise: true)
        if shouldStartAnimation {
            controller.layoutRefreshController.startScrollAnimation(for: workspaceId)
        }
        return true
    }
}
