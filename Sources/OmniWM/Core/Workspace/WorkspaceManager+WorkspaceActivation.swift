// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    @discardableResult
    func swapWorkspaces(
        _ workspace1Id: WorkspaceDescriptor.ID,
        on monitor1Id: Monitor.ID,
        with workspace2Id: WorkspaceDescriptor.ID,
        on monitor2Id: Monitor.ID
    ) -> Bool {
        guard let monitor1 = monitor(byId: monitor1Id),
              let monitor2 = monitor(byId: monitor2Id),
              monitor1Id != monitor2Id else { return false }

        guard isValidAssignment(workspaceId: workspace1Id, monitorId: monitor2.id),
              isValidAssignment(workspaceId: workspace2Id, monitorId: monitor1.id) else { return false }

        let previousPlacement = scriptWorkspaceMoveObserver.map { _ in
            (monitorForWorkspace(workspace1Id), monitorForWorkspace(workspace2Id))
        }
        let previousWorkspace1 = visibleWorkspaceId(on: monitor1.id)
        let previousWorkspace2 = visibleWorkspaceId(on: monitor2.id)

        updateMonitorSession(monitor1.id) { session in
            session.previousVisibleWorkspaceId = previousWorkspace1
            session.visibleWorkspaceId = workspace2Id
        }
        updateWorkspace(workspace2Id) { workspace in
            workspace.assignedMonitorPoint = monitor1.workspaceAnchorPoint
        }

        updateMonitorSession(monitor2.id) { session in
            session.previousVisibleWorkspaceId = previousWorkspace2
            session.visibleWorkspaceId = workspace1Id
        }
        updateWorkspace(workspace1Id) { workspace in
            workspace.assignedMonitorPoint = monitor2.workspaceAnchorPoint
        }

        noteInvalidation(workspaceId: workspace1Id, domains: [.workspace, .layout, .focus])
        noteInvalidation(workspaceId: workspace2Id, domains: [.workspace, .layout, .focus])
        if let previousPlacement {
            withCatalogObserver(.move) { observer in
                observer.workspaceMoved(
                    workspace1Id,
                    from: previousPlacement.0,
                    to: ConfigScriptCatalogMonitor(monitor2),
                    in: self
                )
                observer.workspaceMoved(
                    workspace2Id,
                    from: previousPlacement.1,
                    to: ConfigScriptCatalogMonitor(monitor1),
                    in: self
                )
            }
        }
        notifySessionStateChanged()
        return true
    }

    func setActiveWorkspace(
        _ workspaceId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID,
        updateInteractionMonitor: Bool = true
    ) -> Bool {
        guard let monitor = monitor(byId: monitorId) else { return false }
        return setActiveWorkspaceInternal(
            workspaceId,
            on: monitor.id,
            anchorPoint: monitor.workspaceAnchorPoint,
            updateInteractionMonitor: updateInteractionMonitor
        )
    }

    func assignWorkspaceToMonitor(_ workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID) {
        guard let monitor = monitor(byId: monitorId) else { return }
        guard isValidAssignment(workspaceId: workspaceId, monitorId: monitor.id) else { return }
        updateWorkspace(workspaceId) { $0.assignedMonitorPoint = monitor.workspaceAnchorPoint }
    }
}
