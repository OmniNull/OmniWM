// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func synchronizeConfiguredWorkspaces() {
        let configuredNames = configuredWorkspaceNames()
        let configuredSet = Set(configuredNames)

        for name in configuredNames {
            _ = workspaceId(for: name, createIfMissing: true)
        }

        let toRemove = workspaceCatalog.descriptors.compactMap { workspaceId, workspace -> WorkspaceDescriptor.ID? in
            guard !configuredSet.contains(workspace.name) else { return nil }
            guard windowQueries.windows(in: workspaceId).isEmpty else { return nil }
            return workspaceId
        }
        removeWorkspaces(toRemove)
    }

    func removeWorkspaces(_ ids: [WorkspaceDescriptor.ID]) {
        guard !ids.isEmpty else { return }

        let toRemove = Set(ids)
        for id in toRemove {
            noteInvalidation(workspaceId: id, domains: [.workspace, .layout, .focus])
        }
        let rememberedIds = toRemove.filter {
            focusSessionSnapshot.lastTiledFocusedByWorkspace[$0] != nil
                || focusSessionSnapshot.lastFloatingFocusedByWorkspace[$0] != nil
                || focusSessionSnapshot.lastFocusedByWorkspace[$0] != nil
        }
        if !rememberedIds.isEmpty {
            recordReconcileEvent(.focusForgotten(workspaceIds: rememberedIds, source: .workspaceManager))
        }
        let viewportIds = toRemove.filter { recordedViewportStates[$0] != nil }
        if !viewportIds.isEmpty {
            recordReconcileEvent(.viewportForgotten(workspaceIds: viewportIds, source: .workspaceManager))
        }
        workspaceCatalog.removeDescriptors(ids)
        pendingRuntimeMonitorOverrideClearWorkspaceIds.subtract(toRemove)
        withEngineMutationScope(label: "workspace_removed_engine_cleanup", source: .workspaceManager) {
            for id in toRemove {
                niriEngine?.removeWorkspaceState(id)
                dwindleEngine?.removeLayout(for: id)
            }
        }
        removeWorkspaceRuntimeState(for: ids)

        workspaceCatalog.finishRemovingDescriptors(toRemove)
        invalidateWorkspaceProjectionCaches()

        for monitorId in monitorSessionSnapshots.keys {
            updateMonitorSession(monitorId) { session in
                if let visibleWorkspaceId = session.visibleWorkspaceId,
                   toRemove.contains(visibleWorkspaceId)
                {
                    session.visibleWorkspaceId = nil
                }
                if let previousVisibleWorkspaceId = session.previousVisibleWorkspaceId,
                   toRemove.contains(previousVisibleWorkspaceId)
                {
                    session.previousVisibleWorkspaceId = nil
                }
            }
        }
        reconcileConfiguredVisibleWorkspaces()
        settings.reconcileDynamicHotkeys()
    }
}
