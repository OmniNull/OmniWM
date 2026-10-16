// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func configureWorkspaceNumberHotkeys() {
        settings.liveWorkspaceNamesForHotkeys = { [weak self] in
            self?.workspaceCatalog.descriptors.values.map(\.name) ?? []
        }
        settings.reconcileDynamicHotkeys()
    }

    func garbageCollectUnusedWorkspaces(focusedWorkspaceId: WorkspaceDescriptor.ID?) {
        let configured = configuredWorkspaceNameSet()
        let visible = visibleWorkspaceIds()
        var toRemove: [WorkspaceDescriptor.ID] = []
        for (id, workspace) in workspaceCatalog.descriptors {
            if configured.contains(workspace.name) {
                continue
            }
            if focusedWorkspaceId == id || visible.contains(id) {
                continue
            }
            if windowQueries.windowCount(in: id) != 0 {
                continue
            }
            toRemove.append(id)
        }

        removeWorkspaces(toRemove)
    }

    func sortedWorkspaces() -> [WorkspaceDescriptor] {
        workspaceCatalog.sortedWorkspaces()
    }

    func clearRuntimeMonitorOverrides(
        _ workspaceIds: Set<WorkspaceDescriptor.ID>
    ) -> Set<WorkspaceDescriptor.ID> {
        let context = monitorResolutionContext()
        var cleared: Set<WorkspaceDescriptor.ID> = []
        for workspaceId in workspaceIds {
            guard var workspace = workspaceCatalog.descriptor(for: workspaceId),
                  workspace.runtimeMonitorOverride != nil
            else {
                continue
            }
            workspace.runtimeMonitorOverride = nil
            if let homeMonitor = homeMonitor(for: workspaceId, context: context) {
                workspace.assignedMonitorPoint = homeMonitor.workspaceAnchorPoint
            }
            workspaceCatalog.storeDescriptor(workspace)
            cleared.insert(workspaceId)
        }
        if !cleared.isEmpty {
            workspaceCatalog.invalidateSortedWorkspaces()
        }
        return cleared
    }
}
