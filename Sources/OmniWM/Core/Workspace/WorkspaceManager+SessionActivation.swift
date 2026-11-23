// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func setActiveWorkspaceInternal(
        _ workspaceId: WorkspaceDescriptor.ID,
        on monitorId: Monitor.ID,
        anchorPoint: CGPoint? = nil,
        updateInteractionMonitor: Bool = false,
        notify: Bool = true,
        context: MonitorResolutionContext? = nil
    ) -> Bool {
        let resolutionContext = context ?? monitorResolutionContext()
        guard isValidAssignment(workspaceId: workspaceId, monitorId: monitorId, context: resolutionContext) else {
            return false
        }
        let effectiveAnchorPoint = anchorPoint ?? monitor(byId: monitorId)?.workspaceAnchorPoint
        var workspaceVisibilityChanged = false

        if let prevMonitorId = monitorIdShowingWorkspace(workspaceId),
           prevMonitorId != monitorId
        {
            updateMonitorSession(prevMonitorId) { session in
                session.previousVisibleWorkspaceId = workspaceId
                session.visibleWorkspaceId = nil
            }
            workspaceVisibilityChanged = true
        }

        let previousWorkspaceOnMonitor = visibleWorkspaceId(on: monitorId)
        if previousWorkspaceOnMonitor != workspaceId {
            updateMonitorSession(monitorId) { session in
                if let previousWorkspaceOnMonitor {
                    session.previousVisibleWorkspaceId = previousWorkspaceOnMonitor
                }
                session.visibleWorkspaceId = workspaceId
            }
            workspaceVisibilityChanged = true
        }

        updateWorkspace(workspaceId) { workspace in
            workspace.assignedMonitorPoint = effectiveAnchorPoint
        }

        let interactionChanged = updateInteractionMonitor
            ? self.updateInteractionMonitor(monitorId, preservePrevious: true, notify: false)
            : false
        if workspaceVisibilityChanged || interactionChanged {
            noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout, .focus])
            if let previousWorkspaceOnMonitor {
                noteInvalidation(workspaceId: previousWorkspaceOnMonitor, domains: [.workspace, .layout, .focus])
            }
            if notify {
                notifySessionStateChanged()
            }
        }

        if workspaceVisibilityChanged {
            if let observer = scriptWorkspaceMoveObserver, context == nil {
                observer.refreshWorkspaceMonitorAssignments(
                    for: workspaceId, and: previousWorkspaceOnMonitor, in: self, context: resolutionContext
                )
            }
            drainPendingRuntimeMonitorOverrideClears()
        }
        return true
    }
}
