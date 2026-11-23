// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    @discardableResult
    func moveWorkspaceToMonitor(
        _ workspaceId: WorkspaceDescriptor.ID,
        to targetMonitorId: Monitor.ID,
        force: Bool = false
    ) -> WorkspaceMonitorMoveOutcome {
        guard let workspace = descriptor(for: workspaceId),
              let targetMonitor = monitor(byId: targetMonitorId)
        else {
            return WorkspaceMonitorMoveOutcome(unchanged: .notFound)
        }

        let context = monitorResolutionContext()
        guard let sourceMonitorId = resolvedWorkspaceMonitorId(for: workspaceId, context: context) else {
            return WorkspaceMonitorMoveOutcome(unchanged: .notFound)
        }
        guard sourceMonitorId != targetMonitor.id else {
            return WorkspaceMonitorMoveOutcome(unchanged: .executed)
        }

        let isConfigured = context.configuredWorkspaceNames.contains(workspace.name)
        let homeMonitorId = homeMonitorId(for: workspaceId, context: context)
        if isConfigured, homeMonitorId != targetMonitor.id, !force {
            return WorkspaceMonitorMoveOutcome(unchanged: .conflict)
        }

        return moveWorkspaceToResolvedMonitor(
            workspace,
            from: sourceMonitorId,
            to: targetMonitor,
            homeMonitorId: homeMonitorId,
            context: context
        )
    }

    private func moveWorkspaceToResolvedMonitor(
        _ workspace: WorkspaceDescriptor,
        from sourceMonitorId: Monitor.ID,
        to targetMonitor: Monitor,
        homeMonitorId: Monitor.ID?,
        context: MonitorResolutionContext
    ) -> WorkspaceMonitorMoveOutcome {
        var workspace = workspace
        let workspaceId = workspace.id
        guard let visibility = plannedWorkspaceMonitorMoveVisibility(
            workspaceId,
            from: sourceMonitorId,
            to: targetMonitor.id,
            context: context
        ) else {
            return WorkspaceMonitorMoveOutcome(unchanged: .stateConflict)
        }

        let nextMonitorSessions = plannedWorkspaceMonitorMoveSessions(
            workspaceId,
            from: sourceMonitorId,
            to: targetMonitor.id,
            visibility: visibility
        )

        let floatingStates = translatedFloatingStates(in: workspaceId, to: targetMonitor)
        let floatingRelocations = self.floatingRelocations(in: workspaceId, from: floatingStates)
            .sorted(by: WorkspaceFloatingRelocation.precedes)

        workspace.assignedMonitorPoint = targetMonitor.workspaceAnchorPoint
        workspace.runtimeMonitorOverride = homeMonitorId == targetMonitor.id
            ? nil
            : OutputId(from: targetMonitor)

        commitWorkspaceMonitorMove(
            workspace,
            to: targetMonitor,
            monitorSessions: nextMonitorSessions,
            floatingStates: floatingStates,
            transfersManagedFocus: visibility.transfersManagedFocus
        )

        var affectedWorkspaces: Set<WorkspaceDescriptor.ID> = [workspaceId]
        if let sourceReplacementWorkspaceId = visibility.sourceReplacementWorkspaceId {
            affectedWorkspaces.insert(sourceReplacementWorkspaceId)
        }
        noteInvalidation(
            workspaceIds: affectedWorkspaces,
            domains: [.workspace, .layout, .focus]
        )
        schedulePersistedWindowRestoreCatalogSave()
        scriptWorkspaceMoveObserver?.refreshWorkspaceMonitorAssignments(
            for: workspaceId, and: visibility.destinationWorkspaceId, in: self, context: context
        )
        notifySessionStateChanged()

        return WorkspaceMonitorMoveOutcome(
            status: .executed,
            affectedWorkspaces: affectedWorkspaces,
            floatingRelocations: visibility.makesMovedWorkspaceVisible ? floatingRelocations : []
        )
    }

    private func plannedWorkspaceMonitorMoveVisibility(
        _ workspaceId: WorkspaceDescriptor.ID,
        from sourceMonitorId: Monitor.ID,
        to targetMonitorId: Monitor.ID,
        context: MonitorResolutionContext
    ) -> WorkspaceMonitorMoveVisibility? {
        let visibleBefore = activeVisibleWorkspaceMap()
        let movedWorkspaceWasVisible = visibleBefore[sourceMonitorId] == workspaceId
        let managedFocusedEntry = nativeManagedFocusToken.flatMap { windowQueries.entry(for: $0) }
        let managedFocusedWorkspaceId = managedFocusedEntry?.workspaceId
        let transfersManagedFocus = managedFocusedWorkspaceId == workspaceId
        guard !isWorkspaceMonitorMoveUnsafe(
            workspaceId,
            sourceMonitorId: sourceMonitorId,
            visibleWorkspaces: visibleBefore
        ) else {
            return nil
        }

        let destinationWorkspaceId = visibleBefore[targetMonitorId]
        let destinationIsProtected = targetMonitorId == focusSessionSnapshot.interactionMonitorId
            || destinationWorkspaceId.map {
                $0 == managedFocusedWorkspaceId
                    || $0 == focusSessionSnapshot.pendingManagedFocus.workspaceId
            } ?? false
        let makesMovedWorkspaceVisible = transfersManagedFocus || !destinationIsProtected
        let sourceReplacementWorkspaceId = movedWorkspaceWasVisible
            ? sourceReplacementWorkspaceId(
                for: workspaceId,
                on: sourceMonitorId,
                context: context
            )
            : nil
        return WorkspaceMonitorMoveVisibility(
            sourceWasVisible: movedWorkspaceWasVisible,
            destinationWorkspaceId: destinationWorkspaceId,
            sourceReplacementWorkspaceId: sourceReplacementWorkspaceId,
            makesMovedWorkspaceVisible: makesMovedWorkspaceVisible,
            transfersManagedFocus: transfersManagedFocus
        )
    }

    private func plannedWorkspaceMonitorMoveSessions(
        _ workspaceId: WorkspaceDescriptor.ID,
        from sourceMonitorId: Monitor.ID,
        to targetMonitorId: Monitor.ID,
        visibility: WorkspaceMonitorMoveVisibility
    ) -> [Monitor.ID: MonitorSession] {
        var nextMonitorSessions = monitorSessionSnapshots
        for monitorId in Array(nextMonitorSessions.keys) where monitorId != targetMonitorId {
            guard var session = nextMonitorSessions[monitorId],
                  session.previousVisibleWorkspaceId == workspaceId
            else {
                continue
            }
            session.previousVisibleWorkspaceId = nil
            if session.visibleWorkspaceId == nil {
                nextMonitorSessions.removeValue(forKey: monitorId)
            } else {
                nextMonitorSessions[monitorId] = session
            }
        }
        if visibility.sourceWasVisible {
            var sourceSession = nextMonitorSessions[sourceMonitorId] ?? MonitorSession()
            sourceSession.visibleWorkspaceId = visibility.sourceReplacementWorkspaceId
            sourceSession.previousVisibleWorkspaceId = nil
            if sourceSession.visibleWorkspaceId == nil {
                nextMonitorSessions.removeValue(forKey: sourceMonitorId)
            } else {
                nextMonitorSessions[sourceMonitorId] = sourceSession
            }
        }
        if visibility.makesMovedWorkspaceVisible {
            var targetSession = nextMonitorSessions[targetMonitorId] ?? MonitorSession()
            targetSession.visibleWorkspaceId = workspaceId
            targetSession.previousVisibleWorkspaceId = visibility.destinationWorkspaceId
            nextMonitorSessions[targetMonitorId] = targetSession
        }
        return nextMonitorSessions
    }

    func floatingRelocations(
        in workspaceId: WorkspaceDescriptor.ID,
        from floatingStates: [WindowToken: FloatingState]
    ) -> [WorkspaceFloatingRelocation] {
        return floatingStates.compactMap { token, state -> WorkspaceFloatingRelocation? in
            guard windowQueries.entry(for: token)?.hiddenState == nil else { return nil }
            return WorkspaceFloatingRelocation(
                workspaceId: workspaceId,
                token: token,
                frame: state.lastFrame
            )
        }
    }
}
