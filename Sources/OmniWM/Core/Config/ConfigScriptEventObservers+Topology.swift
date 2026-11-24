// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ConfigScriptEventObservers {
    static func borrowRegistration(
        _ registration: inout ConfigScriptEventObservers?, _ publish: (ConfigScriptEventObservers) -> Void
    ) -> ConfigScriptEventObservers? {
        if registration?.hasSynchronousDelivery == true { return registration }
        if let registration { publish(registration) }
        return nil
    }

    func installTopologyEdges(on controller: WMController, kinds: Set<ConfigScriptEventKind>) {
        let manager = controller.workspaceManager
        if kinds.contains(.workspaceCreated) { manager.scriptWorkspaceCreationObserver = self }
        if kinds.contains(.workspaceRemoved) { manager.scriptWorkspaceRemovalObserver = self }
        if kinds.contains(.workspaceMoveToMonitor) {
            manager.scriptWorkspaceMoveObserver = self
            catalogMonitorContext = manager.monitorResolutionContext()
        }
        if kinds.contains(.monitorAdded) || kinds.contains(.monitorRemoved) || kinds.contains(.monitorLayoutChanged) {
            manager.scriptTopologyObserver = self
        }
    }

    func detachTopologyEdges(from controller: WMController) {
        let manager = controller.workspaceManager
        if manager.scriptWorkspaceCreationObserver === self { manager.scriptWorkspaceCreationObserver = nil }
        if manager.scriptWorkspaceRemovalObserver === self { manager.scriptWorkspaceRemovalObserver = nil }
        if manager.scriptWorkspaceMoveObserver === self { manager.scriptWorkspaceMoveObserver = nil }
        if manager.scriptTopologyObserver === self { manager.scriptTopologyObserver = nil }
        catalogMonitorContext = nil
    }

    func workspaceCreated(_ workspace: WorkspaceDescriptor, in manager: WorkspaceManager) {
        workspaceEdge(
            .workspaceCreated,
            id: workspace.id,
            name: workspace.name,
            monitor: manager.configCatalogMonitor(for: workspace.id), in: manager
        )
    }

    func workspaceEdge(
        _ kind: ConfigScriptEventKind, id: WorkspaceDescriptor.ID, name: consuming String,
        monitor: ConfigScriptCatalogMonitor?, previous: ConfigScriptCatalogMonitor? = nil, in manager: WorkspaceManager
    ) {
        publishNative(kind, .init(id: .workspace(id), name: consume name, edge: .monitor(
            id: monitor?.id, name: monitor?.name, previousId: previous?.id, previousName: previous?.name
        )), in: manager)
    }

    func workspaceMoves(
        _ workspace: (id: WorkspaceDescriptor.ID, previous: Monitor?), to target: Monitor?,
        displacing other: WorkspaceDescriptor.ID?, in manager: WorkspaceManager,
        context: WorkspaceManager.MonitorResolutionContext
    ) {
        guard let target else { return }
        workspaceMoved(workspace.id, from: workspace.previous, to: ConfigScriptCatalogMonitor(target), in: manager)
        if let other, other != workspace.id {
            workspaceMoved(
                other,
                from: target,
                to: manager.configCatalogMonitor(for: other, context: context),
                in: manager
            )
        }
    }

    func workspaceMoved(
        _ id: WorkspaceDescriptor.ID, from previous: Monitor?, to current: ConfigScriptCatalogMonitor?,
        in manager: WorkspaceManager
    ) {
        guard let previous, let current, previous.id != current.id, let name = manager.workspaceCatalog.name(for: id)
        else { return }
        workspaceEdge(
            .workspaceMoveToMonitor,
            id: id,
            name: consume name,
            monitor: current,
            previous: ConfigScriptCatalogMonitor(previous), in: manager
        )
    }

    func catalogPlacements(in manager: WorkspaceManager) -> ConfigScriptCatalogPlacements {
        ConfigScriptCatalogPlacements(
            monitors: manager.monitors, visible: manager.visibleWorkspaceMap(),
            assigned: manager.projections.workspaceIdsByMonitor(context: catalogMonitorContext)
        )
    }

    func catalogCommitted(previous: ConfigScriptCatalogPlacements, in manager: WorkspaceManager) {
        catalogMonitorContext = manager.monitorResolutionContext()
        let current = catalogPlacements(in: manager)
        guard previous.visible != current.visible || previous.assigned != current.assigned else { return }
        var oldCursor = ConfigScriptCatalogCursor()
        var newCursor = ConfigScriptCatalogCursor()
        for workspace in manager.sortedWorkspaces() {
            let old = previous.monitorIndex(for: workspace.id, in: manager.workspaceCatalog, cursor: &oldCursor)
            let new = current.monitorIndex(for: workspace.id, in: manager.workspaceCatalog, cursor: &newCursor)
            guard let old, let new, previous.monitors[old].id != current.monitors[new].id else { continue }
            workspaceEdge(
                .workspaceMoveToMonitor,
                id: workspace.id,
                name: workspace.name,
                monitor: ConfigScriptCatalogMonitor(current.monitors[new]),
                previous: ConfigScriptCatalogMonitor(previous.monitors[old]), in: manager
            )
        }
    }

    func topologyCommitted(previous: borrowing [Monitor], current: borrowing [Monitor], in manager: WorkspaceManager) {
        if kinds.contains(.monitorRemoved) {
            for index in previous.indices where !manager.hasMonitor(previous[index].id) {
                geometryEdge(.monitorRemoved, previous[index], in: manager)
            }
        }
        let added = kinds.contains(.monitorAdded)
        let layout = kinds.contains(.monitorLayoutChanged)
        guard added || layout else { return }
        for index in current.indices {
            if let old = Self.monitorIndex(current[index].id, in: previous) {
                if layout,
                   current[index].frame != previous[old].frame || current[index].visibleFrame != previous[old]
                       .visibleFrame
                {
                    geometryEdge(
                        .monitorLayoutChanged,
                        current[index],
                        previousFrame: previous[old].frame,
                        previousVisibleFrame: previous[old].visibleFrame, in: manager
                    )
                }
            } else if added {
                geometryEdge(.monitorAdded, current[index], in: manager)
            }
        }
    }

    private static func monitorIndex(_ id: Monitor.ID, in monitors: borrowing [Monitor]) -> Int? {
        for index in monitors.indices where monitors[index].id == id { return index }
        return nil
    }

    private func geometryEdge(
        _ kind: ConfigScriptEventKind, _ monitor: borrowing Monitor,
        previousFrame: CGRect? = nil, previousVisibleFrame: CGRect? = nil, in manager: WorkspaceManager
    ) {
        publishNative(kind, .init(id: .monitor(monitor.id), name: monitor.name, edge: .geometry(
            frame: monitor.frame, previousFrame: previousFrame,
            visibleFrame: monitor.visibleFrame, previousVisibleFrame: previousVisibleFrame
        )), in: manager)
    }
}

struct ConfigScriptCatalogPlacements {
    let monitors: [Monitor]
    let visible: [Monitor.ID: WorkspaceDescriptor.ID]
    let assigned: [Monitor.ID: [WorkspaceDescriptor.ID]]

    @MainActor
    func monitorIndex(
        for workspace: WorkspaceDescriptor.ID, in catalog: WorkspaceCatalog, cursor: inout ConfigScriptCatalogCursor
    ) -> Int? {
        var assignedIndex: Int?
        var visibleIndex: Int?
        for index in monitors.indices {
            let id = monitors[index].id
            if visibleIndex == nil, visible[id] == workspace { visibleIndex = index }
            if assignedIndex == nil, let bucket = assigned.index(forKey: id),
               cursor.includes(workspace, at: index, in: assigned.values[bucket], catalog: catalog)
            {
                assignedIndex = index
            }
        }
        return visibleIndex ?? assignedIndex
    }
}

typealias ConfigScriptCatalogBuffer<Element> = InlineArray<64, Element>

struct ConfigScriptCatalogCursor {
    private var positions = ConfigScriptCatalogBuffer<Int>(repeating: 0)

    @MainActor
    mutating func includes(
        _ workspace: WorkspaceDescriptor.ID, at monitorIndex: Int, in bucket: borrowing [WorkspaceDescriptor.ID],
        catalog: WorkspaceCatalog
    ) -> Bool {
        let ids = bucket.span
        guard monitorIndex < positions.count else {
            for index in ids.indices where ids[index] == workspace { return true }
            return false
        }
        var position = positions[monitorIndex]
        while position < ids.count {
            let candidate = ids[position]
            if candidate == workspace {
                positions[monitorIndex] = position + 1
                return true
            }
            if catalog.name(for: candidate) != nil { break }
            position += 1
        }
        positions[monitorIndex] = position
        return false
    }
}

struct ConfigScriptCatalogMonitor {
    let id: Monitor.ID
    let name: String

    init(_ monitor: borrowing Monitor) {
        id = monitor.id
        name = monitor.name
    }

    init(stored monitor: inout Monitor) {
        self.init(monitor)
    }

    static func visibleID(for workspace: WorkspaceDescriptor.ID, in sessions: inout [Monitor.ID: MonitorSession])
        -> Monitor.ID?
    {
        var index = sessions.startIndex
        while index != sessions.endIndex {
            if sessions.values[index].visibleWorkspaceId == workspace { return sessions.keys[index] }
            sessions.formIndex(after: &index)
        }
        return nil
    }
}

extension WorkspaceManager {
    enum CatalogPublication {
        case creation, move, topology
    }

    func withCatalogObserver(_ publication: CatalogPublication, _ publish: (ConfigScriptEventObservers) -> Void) {
        let client: ConfigScriptEventObservers? = switch publication {
        case .creation: ConfigScriptEventObservers.borrowRegistration(&scriptWorkspaceCreationObserver, publish)
        case .move: ConfigScriptEventObservers.borrowRegistration(&scriptWorkspaceMoveObserver, publish)
        case .topology: ConfigScriptEventObservers.borrowRegistration(&scriptTopologyObserver, publish)
        }
        if let client { publish(client) }
    }

    func publishCatalogMoves(
        _ workspace: (id: WorkspaceDescriptor.ID, previous: Monitor?), to target: @autoclosure () -> Monitor?,
        displacing other: WorkspaceDescriptor.ID?, context: MonitorResolutionContext
    ) {
        withCatalogObserver(.move) {
            $0.workspaceMoves(workspace, to: target(), displacing: other, in: self, context: context)
        }
    }

    func configCatalogMonitor(
        for workspace: WorkspaceDescriptor.ID, context: MonitorResolutionContext? = nil
    ) -> ConfigScriptCatalogMonitor? {
        if let id = configVisibleMonitorID(for: workspace) {
            return configCatalogMonitor(byId: id)
        }
        guard workspaceCatalog.contains(workspace) else { return nil }
        if monitors.count == 1 { return ConfigScriptCatalogMonitor(monitors[0]) }
        if let id = projections.cachedAssignedMonitor(for: workspace), let monitor = configCatalogMonitor(byId: id) {
            return monitor
        }
        guard let monitor = effectiveMonitor(
            for: workspace, context: context ?? monitorResolutionContext(), visibleMonitorId: nil
        )
        else { return nil }
        return ConfigScriptCatalogMonitor(monitor)
    }
}
