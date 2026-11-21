// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WorkspaceManager {
    func invalidateSettingsProjectionCaches() {
        projections.invalidateSettingsProjectionCaches()
    }

    func invalidateWorkspaceProjectionCaches() {
        projections.invalidateWorkspaceProjectionCaches()
    }

    func sortedMonitors() -> [Monitor] {
        projections.sortedMonitors()
    }

    func currentTopologyProfile() -> TopologyProfile {
        projections.currentTopologyProfile()
    }

    func configuredWorkspaceNames() -> [String] {
        projections.configuredWorkspaceNames()
    }

    func configuredWorkspaceNameSet() -> Set<String> {
        projections.configuredWorkspaceNameSet()
    }

    func monitorDescriptionByWorkspaceName() -> [String: MonitorDescription] {
        projections.monitorDescriptionByWorkspaceName()
    }

    func workspaceIdsByMonitor() -> [Monitor.ID: [WorkspaceDescriptor.ID]] {
        projections.workspaceIdsByMonitor()
    }

    func monitorIdShowingWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        projections.monitorIdShowingWorkspace(workspaceId)
    }

    func visibleWorkspaceIds() -> Set<WorkspaceDescriptor.ID> {
        projections.visibleWorkspaceIds()
    }

    func visibleWorkspaceMap() -> [Monitor.ID: WorkspaceDescriptor.ID] {
        projections.visibleWorkspaceMap()
    }
}
