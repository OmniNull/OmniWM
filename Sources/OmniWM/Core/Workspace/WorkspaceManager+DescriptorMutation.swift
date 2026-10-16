// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC
import QuartzCore

extension WorkspaceManager {
    func updateWorkspace(_ workspaceId: WorkspaceDescriptor.ID, update: (inout WorkspaceDescriptor) -> Void) {
        guard let result = workspaceCatalog.updateWorkspace(workspaceId, update: update) else { return }
        invalidateWorkspaceProjectionCaches()
        if result.previous != result.current {
            noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout])
            schedulePersistedWindowRestoreCatalogSave()
        }
    }

    func createWorkspace(
        named name: String,
        assignedMonitorPoint: CGPoint? = nil,
        requiresConfiguration: Bool = true
    ) -> WorkspaceDescriptor.ID? {
        guard let rawID = WorkspaceIDPolicy.normalizeRawID(name) else { return nil }
        guard !requiresConfiguration || configuredWorkspaceNameSet().contains(rawID) else { return nil }
        let workspace = WorkspaceDescriptor(name: rawID, assignedMonitorPoint: assignedMonitorPoint)
        workspaceCatalog.insertWorkspace(workspace)
        invalidateWorkspaceProjectionCaches()
        noteInvalidation(workspaceId: workspace.id, domains: [.workspace, .layout, .focus])
        settings.reconcileDynamicHotkeys()
        return workspace.id
    }
}
