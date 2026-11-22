// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension DwindleLayoutHandler {
    @discardableResult
    func applyFramesOnDemand(
        workspaceId wsId: WorkspaceDescriptor.ID,
        monitor: Monitor,
        isInteractiveMove: Bool = false,
        activeMonitor: (workspace: WorkspaceDescriptor.ID, geometry: LayoutMonitorSnapshot)? = nil
    ) -> Bool {
        guard let controller,
              let activeWorkspaceId = activeMonitor?.workspace ?? controller.workspaceManager
                  .activeWorkspaceOrFirst(on: monitor.id)?.id,
              let engine = controller.dwindleEngine,
              let snapshot = makeWorkspaceSnapshot(
                  workspaceId: wsId,
                  monitor: monitor,
                  resolveConstraints: false,
                  isActiveWorkspace: activeWorkspaceId == wsId, geometry: activeMonitor?.geometry
              )
        else {
            return false
        }

        let plan = buildOnDemandLayoutPlan(
            snapshot: snapshot,
            engine: engine,
            isInteractiveMove: isInteractiveMove
        )
        return controller.layoutRefreshController.executeLayoutPlan(plan)
    }

    func refreshEngineConstraints(workspaceId: WorkspaceDescriptor.ID, monitor: Monitor) {
        guard let controller,
              let engine = controller.dwindleEngine,
              let activeWorkspaceId = controller.workspaceManager.activeWorkspaceOrFirst(on: monitor.id)?.id,
              let refreshInput = controller.layoutRefreshController.buildRefreshInput(
                  workspaceId: workspaceId,
                  monitor: monitor,
                  resolveConstraints: true,
                  isActiveWorkspace: activeWorkspaceId == workspaceId
              )
        else {
            return
        }

        controller.workspaceManager.withEngineMutationScope {
            for window in refreshInput.windows {
                engine.updateWindowConstraints(for: window.token, constraints: window.constraints)
            }
        }
    }
}
