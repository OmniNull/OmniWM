// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func resolvedWorkspaceMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        resolvedWorkspaceMonitorId(for: workspaceId, context: monitorResolutionContext())
    }

    func resolvedWorkspaceMonitorId(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor.ID? {
        return monitorIdShowingWorkspace(workspaceId)
            ?? effectiveMonitor(for: workspaceId, context: context)?.id
    }

    func workspaceMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        resolvedWorkspaceMonitorId(for: workspaceId)
    }

    func workspaceMonitorId(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor.ID? {
        resolvedWorkspaceMonitorId(for: workspaceId, context: context)
    }

    func configuredMonitorDescription(
        for workspaceName: String,
        context: MonitorResolutionContext
    ) -> MonitorDescription? {
        context.monitorDescriptionByWorkspaceName[workspaceName]
    }

    func homeMonitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        homeMonitor(for: workspaceId, context: monitorResolutionContext())
    }

    func homeMonitor(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor? {
        guard let workspace = descriptor(for: workspaceId) else { return nil }
        guard let description = configuredMonitorDescription(for: workspace.name, context: context) else { return nil }
        return description.resolveMonitor(sortedMonitors: context.sortedMonitors, ranking: context.monitorRanking)
    }

    func homeMonitorId(for workspaceId: WorkspaceDescriptor.ID) -> Monitor.ID? {
        homeMonitorId(for: workspaceId, context: monitorResolutionContext())
    }

    func homeMonitorId(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor.ID? {
        homeMonitor(for: workspaceId, context: context)?.id
    }

    func effectiveMonitor(for workspaceId: WorkspaceDescriptor.ID) -> Monitor? {
        effectiveMonitor(for: workspaceId, context: monitorResolutionContext())
    }

    func effectiveMonitor(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor? {
        effectiveMonitor(for: workspaceId, context: context, visibleMonitorId: monitorIdShowingWorkspace(workspaceId))
    }

    func effectiveMonitor(
        for workspaceId: WorkspaceDescriptor.ID, context: MonitorResolutionContext,
        visibleMonitorId: @autoclosure () -> Monitor.ID?
    ) -> Monitor? {
        guard let workspace = descriptor(for: workspaceId) else { return nil }
        return effectiveMonitor(
            for: workspace, sortedMonitors: context.sortedMonitors, ranking: context.monitorRanking,
            description: configuredMonitorDescription(for: workspace.name, context: context),
            visibleMonitorId: visibleMonitorId()
        )
    }

    func effectiveMonitor(
        for workspace: WorkspaceDescriptor, sortedMonitors: [Monitor], ranking: @autoclosure () -> [OutputId],
        description: @autoclosure () -> MonitorDescription?, visibleMonitorId: @autoclosure () -> Monitor.ID?
    ) -> Monitor? {
        if let runtimeOverride = workspace.runtimeMonitorOverride,
           let monitor = runtimeOverride.resolveMonitor(in: sortedMonitors)
        {
            return monitor
        }

        if let home = description()?.resolveMonitor(sortedMonitors: sortedMonitors, ranking: ranking()) {
            return home
        }

        guard !sortedMonitors.isEmpty else { return nil }

        let anchorPoint = workspace.assignedMonitorPoint
            ?? visibleMonitorId().flatMap { monitor(byId: $0)?.workspaceAnchorPoint }
        guard let anchorPoint else { return sortedMonitors.first }
        return sortedMonitors.min { lhs, rhs in
            let lhsDistance = lhs.workspaceAnchorPoint.distanceSquared(to: anchorPoint)
            let rhsDistance = rhs.workspaceAnchorPoint.distanceSquared(to: anchorPoint)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }
            return MonitorRestoreOrder(monitor: lhs) < MonitorRestoreOrder(monitor: rhs)
        }
    }

    func isValidAssignment(workspaceId: WorkspaceDescriptor.ID, monitorId: Monitor.ID) -> Bool {
        isValidAssignment(workspaceId: workspaceId, monitorId: monitorId, context: monitorResolutionContext())
    }

    func isValidAssignment(
        workspaceId: WorkspaceDescriptor.ID,
        monitorId: Monitor.ID,
        context: MonitorResolutionContext
    ) -> Bool {
        guard descriptor(for: workspaceId) != nil else { return false }
        return effectiveMonitor(for: workspaceId, context: context)?.id == monitorId
    }

    func monitor(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor? {
        guard let monitorId = workspaceMonitorId(for: workspaceId, context: context) else { return nil }
        return monitor(byId: monitorId)
    }

    func monitorId(
        for workspaceId: WorkspaceDescriptor.ID,
        context: MonitorResolutionContext
    ) -> Monitor.ID? {
        monitor(for: workspaceId, context: context)?.id
    }
}
