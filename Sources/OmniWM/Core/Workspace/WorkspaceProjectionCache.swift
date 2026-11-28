// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

@MainActor
final class WorkspaceProjectionCache {
    private unowned let manager: WorkspaceManager
    private var _cachedSortedMonitors: [Monitor]?
    private var _cachedTopologyProfile: TopologyProfile?
    private var _cachedConfiguredWorkspaceNames: [String]?
    private var _cachedConfiguredWorkspaceNameSet: Set<String>?
    private var _cachedMonitorDescriptionByWorkspaceName: [String: MonitorDescription]?
    private var _cachedWorkspaceIdsByMonitor: [Monitor.ID: [WorkspaceDescriptor.ID]]?
    private var _cachedVisibleWorkspaceIds: Set<WorkspaceDescriptor.ID>?
    private var _cachedVisibleWorkspaceMap: [Monitor.ID: WorkspaceDescriptor.ID]?
    private var _cachedMonitorIdByVisibleWorkspace: [WorkspaceDescriptor.ID: Monitor.ID]?

    init(manager: WorkspaceManager) {
        self.manager = manager
    }

    func invalidateMonitorProjections() {
        _cachedSortedMonitors = nil
        _cachedTopologyProfile = nil
    }

    func invalidateSettingsProjectionCaches() {
        _cachedConfiguredWorkspaceNames = nil
        _cachedConfiguredWorkspaceNameSet = nil
        _cachedMonitorDescriptionByWorkspaceName = nil
    }

    func invalidateWorkspaceProjectionCaches() {
        _cachedWorkspaceIdsByMonitor = nil
        _cachedVisibleWorkspaceIds = nil
        _cachedVisibleWorkspaceMap = nil
        _cachedMonitorIdByVisibleWorkspace = nil
    }

    func sortedMonitors() -> [Monitor] {
        if let cached = _cachedSortedMonitors {
            return cached
        }
        let sorted = Monitor.sortedByPosition(manager.monitors)
        _cachedSortedMonitors = sorted
        return sorted
    }

    func currentTopologyProfile() -> TopologyProfile {
        if let cached = _cachedTopologyProfile {
            return cached
        }
        let profile = TopologyProfile(sortedMonitors: sortedMonitors())
        _cachedTopologyProfile = profile
        return profile
    }

    func configuredWorkspaceNames() -> [String] {
        if let cached = _cachedConfiguredWorkspaceNames {
            return cached
        }
        let names = manager.settings.workspaces.configuredNames()
        _cachedConfiguredWorkspaceNames = names
        return names
    }

    func configuredWorkspaceNameSet() -> Set<String> {
        if let cached = _cachedConfiguredWorkspaceNameSet {
            return cached
        }
        let names = Set(configuredWorkspaceNames())
        _cachedConfiguredWorkspaceNameSet = names
        return names
    }

    func monitorDescriptionByWorkspaceName() -> [String: MonitorDescription] {
        if let cached = _cachedMonitorDescriptionByWorkspaceName {
            return cached
        }
        var descriptions: [String: MonitorDescription] = [:]
        for configuration in manager.settings.workspaces.configurations {
            descriptions[configuration.name] = configuration.monitorAssignment.toMonitorDescription()
        }
        _cachedMonitorDescriptionByWorkspaceName = descriptions
        return descriptions
    }

    func cachedAssignedMonitor(for workspace: WorkspaceDescriptor.ID) -> Monitor.ID? {
        _cachedWorkspaceIdsByMonitor?.first(where: { $0.value.contains(workspace) })?.key
    }

    func workspaceIdsByMonitor(
        context: @autoclosure () -> WorkspaceManager.MonitorResolutionContext? = nil
    ) -> [Monitor.ID: [WorkspaceDescriptor.ID]] {
        if let cached = _cachedWorkspaceIdsByMonitor {
            return cached
        }

        let context = context() ?? manager.monitorResolutionContext()
        var workspaceIdsByMonitor: [Monitor.ID: [WorkspaceDescriptor.ID]] = [:]
        for workspace in manager.sortedWorkspaces() {
            guard let monitorId = manager.effectiveMonitor(for: workspace.id, context: context)?.id else { continue }
            workspaceIdsByMonitor[monitorId, default: []].append(workspace.id)
        }

        _cachedWorkspaceIdsByMonitor = workspaceIdsByMonitor
        return workspaceIdsByMonitor
    }

    func visibleWorkspaceMap() -> [Monitor.ID: WorkspaceDescriptor.ID] {
        if let cached = _cachedVisibleWorkspaceMap {
            return cached
        }

        let visibleWorkspaceMap = manager.activeVisibleWorkspaceMap(from: manager.monitorSessionSnapshots)
        _cachedVisibleWorkspaceMap = visibleWorkspaceMap
        _cachedMonitorIdByVisibleWorkspace = Dictionary(
            uniqueKeysWithValues: visibleWorkspaceMap.map { ($0.value, $0.key) }
        )
        _cachedVisibleWorkspaceIds = Set(visibleWorkspaceMap.values)
        return visibleWorkspaceMap
    }

    func visibleWorkspaceIds() -> Set<WorkspaceDescriptor.ID> {
        if let cached = _cachedVisibleWorkspaceIds {
            return cached
        }
        return Set(visibleWorkspaceMap().values)
    }

    func monitorIdShowingWorkspace(_ workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        if let cached = _cachedMonitorIdByVisibleWorkspace {
            return cached[workspaceId]
        }
        _ = visibleWorkspaceMap()
        return _cachedMonitorIdByVisibleWorkspace?[workspaceId]
    }
}
