// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func workspaces(on monitorId: Monitor.ID) -> [WorkspaceDescriptor] {
        workspaceIdsByMonitor()[monitorId]?.compactMap(descriptor(for:)) ?? []
    }

    func primaryWorkspace() -> WorkspaceDescriptor? {
        let monitor = monitors.first(where: { $0.isMain }) ?? monitors.first
        guard let monitor else { return nil }
        return activeWorkspaceOrFirst(on: monitor.id)
    }

    func activeWorkspace(on monitorId: Monitor.ID) -> WorkspaceDescriptor? {
        guard let mon = monitor(byId: monitorId) else { return nil }
        guard let workspaceId = visibleWorkspaceId(on: mon.id) else { return nil }
        return descriptor(for: workspaceId)
    }

    func previousWorkspace(on monitorId: Monitor.ID) -> WorkspaceDescriptor? {
        guard let monitor = monitor(byId: monitorId) else { return nil }
        guard let prevId = previousVisibleWorkspaceId(on: monitor.id) else { return nil }
        guard prevId != visibleWorkspaceId(on: monitor.id) else { return nil }
        return descriptor(for: prevId)
    }

    func nextWorkspaceInOrder(
        on monitorId: Monitor.ID,
        from workspaceId: WorkspaceDescriptor.ID,
        wrapAround: Bool,
        skipEmpty: Bool = false
    ) -> WorkspaceDescriptor? {
        adjacentWorkspaceInOrder(
            on: monitorId,
            from: workspaceId,
            offset: 1,
            wrapAround: wrapAround,
            skipEmpty: skipEmpty
        )
    }

    func previousWorkspaceInOrder(
        on monitorId: Monitor.ID,
        from workspaceId: WorkspaceDescriptor.ID,
        wrapAround: Bool,
        skipEmpty: Bool = false
    ) -> WorkspaceDescriptor? {
        adjacentWorkspaceInOrder(
            on: monitorId,
            from: workspaceId,
            offset: -1,
            wrapAround: wrapAround,
            skipEmpty: skipEmpty
        )
    }

    /// A workspace counts as occupied when it holds a tiled window or a non-scratchpad floating window.
    func isOccupied(_ workspaceId: WorkspaceDescriptor.ID) -> Bool {
        !barVisibleEntries(in: workspaceId, showFloatingWindows: true).isEmpty
    }

    func activeWorkspaceOrFirst(on monitorId: Monitor.ID) -> WorkspaceDescriptor? {
        if let active = activeWorkspace(on: monitorId) {
            return active
        }
        guard let defaultWorkspaceId = defaultVisibleWorkspaceId(on: monitorId) else { return nil }
        return descriptor(for: defaultWorkspaceId)
    }

    private func adjacentWorkspaceInOrder(
        on monitorId: Monitor.ID,
        from workspaceId: WorkspaceDescriptor.ID,
        offset: Int,
        wrapAround: Bool,
        skipEmpty: Bool
    ) -> WorkspaceDescriptor? {
        var ordered = workspaces(on: monitorId)
        if skipEmpty {
            ordered = ordered.filter { $0.id == workspaceId || isOccupied($0.id) }
        }
        guard ordered.count > 1 else { return nil }
        guard let currentIdx = ordered.firstIndex(where: { $0.id == workspaceId }) else { return nil }

        let targetIdx = currentIdx + offset
        if wrapAround {
            let wrappedIdx = (targetIdx % ordered.count + ordered.count) % ordered.count
            return ordered[wrappedIdx]
        }
        guard ordered.indices.contains(targetIdx) else { return nil }
        return ordered[targetIdx]
    }

    func focusWorkspace(named name: String) -> (workspace: WorkspaceDescriptor, monitor: Monitor)? {
        ensureVisibleWorkspaces()
        guard let workspaceId = workspaceId(for: name, createIfMissing: false) else { return nil }
        return focusWorkspace(id: workspaceId)
    }

    func focusWorkspace(id workspaceId: WorkspaceDescriptor.ID) -> (workspace: WorkspaceDescriptor, monitor: Monitor)? {
        ensureVisibleWorkspaces()
        guard let targetMonitor = monitorForWorkspace(workspaceId) else { return nil }
        guard setActiveWorkspace(workspaceId, on: targetMonitor.id) else { return nil }
        guard let workspace = descriptor(for: workspaceId),
              let resolvedMonitor = monitorForWorkspace(workspaceId)
        else {
            return nil
        }
        return (workspace, resolvedMonitor)
    }
}
