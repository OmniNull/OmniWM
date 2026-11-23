// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension ConfigScriptEventObservers {
    func installTopologyEdges(on controller: WMController, kinds: Set<ConfigScriptEventKind>) {
        let manager = controller.workspaceManager
        let tracksMoves = kinds.contains(.workspaceMoveToMonitor)
        if tracksMoves || kinds.contains(.workspaceCreated) { manager.scriptWorkspaceCreationObserver = self }
        if tracksMoves || kinds.contains(.workspaceRemoved) { manager.scriptWorkspaceRemovalObserver = self }
        if tracksMoves {
            manager.scriptWorkspaceMoveObserver = self
            refreshWorkspaceMonitorAssignments(in: manager)
        }
        if tracksMoves || kinds.contains(.monitorAdded) || kinds.contains(.monitorRemoved)
            || kinds.contains(.monitorLayoutChanged)
        {
            manager.scriptTopologyObserver = self
        }
    }

    func detachTopologyEdges(from controller: WMController) {
        let manager = controller.workspaceManager
        if manager.scriptWorkspaceCreationObserver === self { manager.scriptWorkspaceCreationObserver = nil }
        if manager.scriptWorkspaceRemovalObserver === self { manager.scriptWorkspaceRemovalObserver = nil }
        if manager.scriptWorkspaceMoveObserver === self { manager.scriptWorkspaceMoveObserver = nil }
        if manager.scriptTopologyObserver === self { manager.scriptTopologyObserver = nil }
    }

    func workspaceCreated(_ workspace: WorkspaceDescriptor, in manager: WorkspaceManager) {
        let monitor = manager.monitorForWorkspace(workspace.id)
        if kinds.contains(.workspaceMoveToMonitor) {
            workspaceMonitorAssignments[workspace.id] = monitor.map { ($0.id, $0.name) }
        }
        if kinds.contains(.workspaceCreated) {
            emit(.workspaceCreated, workspacePayload(workspace, on: monitor))
        }
    }

    func removalPayloads(
        for ids: [WorkspaceDescriptor.ID], in manager: WorkspaceManager
    ) -> [ConfigScriptEventPayload] {
        guard kinds.contains(.workspaceRemoved) else { return [] }
        var seen = Set<WorkspaceDescriptor.ID>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted, let descriptor = manager.descriptor(for: id) else { return nil }
            return workspacePayload(descriptor, on: manager.monitorForWorkspace(id))
        }
    }

    func workspacesRemoved(_ ids: [WorkspaceDescriptor.ID], payloads: [ConfigScriptEventPayload]) {
        if kinds.contains(.workspaceMoveToMonitor) {
            for id in ids { workspaceMonitorAssignments.removeValue(forKey: id) }
        }
        for payload in payloads { emit(.workspaceRemoved, payload) }
    }

    func refreshWorkspaceMonitorAssignments(in manager: WorkspaceManager) {
        let context = manager.monitorResolutionContext()
        for workspace in manager.sortedWorkspaces() {
            updateWorkspaceMonitor(workspace, on: manager.monitor(for: workspace.id, context: context))
        }
    }

    func refreshWorkspaceMonitorAssignments(
        for workspaceId: WorkspaceDescriptor.ID, and otherId: WorkspaceDescriptor.ID?,
        in manager: WorkspaceManager, context: WorkspaceManager.MonitorResolutionContext
    ) {
        if let workspace = manager.descriptor(for: workspaceId) {
            updateWorkspaceMonitor(workspace, on: manager.monitor(for: workspaceId, context: context))
        }
        if let otherId, let workspace = manager.descriptor(for: otherId) {
            updateWorkspaceMonitor(workspace, on: manager.monitor(for: otherId, context: context))
        }
    }

    private func updateWorkspaceMonitor(_ workspace: WorkspaceDescriptor, on current: Monitor?) {
        let previous = workspaceMonitorAssignments[workspace.id]
        guard current?.id != previous?.id || current?.name != previous?.name else { return }
        workspaceMonitorAssignments[workspace.id] = current.map { ($0.id, $0.name) }
        if let previous, let current, previous.id != current.id {
            emit(.workspaceMoveToMonitor, workspacePayload(workspace, on: current, from: previous))
        }
    }

    private func workspacePayload(
        _ workspace: WorkspaceDescriptor, on monitor: Monitor?, from previous: MonitorIdentity? = nil
    ) -> ConfigScriptEventPayload {
        .init(id: workspace.id.uuidString, name: workspace.name, edge: .monitor(
            id: monitor.map { IPCDisplayRef.identifier($0.id) }, name: monitor?.name,
            previousId: previous.map { IPCDisplayRef.identifier($0.id) }, previousName: previous?.name
        ))
    }

    func topologyCommitted(previous: [Monitor], in manager: WorkspaceManager) {
        let current = manager.monitors
        if kinds.contains(.monitorRemoved) {
            for monitor in previous where manager.monitor(byId: monitor.id) == nil {
                emit(.monitorRemoved, geometryPayload(monitor))
            }
        }
        let added = kinds.contains(.monitorAdded)
        let layout = kinds.contains(.monitorLayoutChanged)
        if added || layout {
            for monitor in current {
                if let old = previous.first(where: { $0.id == monitor.id }) {
                    if layout, monitor.frame != old.frame || monitor.visibleFrame != old.visibleFrame {
                        emit(.monitorLayoutChanged, geometryPayload(monitor, previous: old))
                    }
                } else if added {
                    emit(.monitorAdded, geometryPayload(monitor))
                }
            }
        }
        if kinds.contains(.workspaceMoveToMonitor) { refreshWorkspaceMonitorAssignments(in: manager) }
    }

    private func geometryPayload(_ monitor: Monitor, previous: Monitor? = nil) -> ConfigScriptEventPayload {
        .init(id: IPCDisplayRef.identifier(monitor.id), name: monitor.name, edge: .geometry(
            frame: monitor.frame, previousFrame: previous?.frame,
            visibleFrame: monitor.visibleFrame, previousVisibleFrame: previous?.visibleFrame
        ))
    }
}
