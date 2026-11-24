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
        let visibleMonitor = monitorIdShowingWorkspace(workspaceId)
        let previousMonitor = context == nil && scriptWorkspaceMoveObserver != nil
            ? monitor(byId: visibleMonitor ?? monitorId)
            : nil
        var workspaceVisibilityChanged = false

        if let prevMonitorId = visibleMonitor,
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
            invalidateWorkspaceActivation(workspaceId, previous: previousWorkspaceOnMonitor, notify: notify)
        }

        if workspaceVisibilityChanged {
            if context == nil {
                publishCatalogMoves(
                    (workspaceId, previousMonitor), to: monitor(byId: monitorId),
                    displacing: previousWorkspaceOnMonitor, context: resolutionContext
                )
            }
            drainPendingRuntimeMonitorOverrideClears()
        }
        return true
    }

    private func invalidateWorkspaceActivation(
        _ workspaceId: WorkspaceDescriptor.ID, previous: WorkspaceDescriptor.ID?, notify: Bool
    ) {
        noteInvalidation(workspaceId: workspaceId, domains: [.workspace, .layout, .focus])
        if let previous { noteInvalidation(workspaceId: previous, domains: [.workspace, .layout, .focus]) }
        if notify { notifySessionStateChanged() }
    }
}
