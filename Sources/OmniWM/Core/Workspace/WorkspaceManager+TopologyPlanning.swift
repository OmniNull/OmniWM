// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    @discardableResult
    func recordTopologyChange(to newMonitors: [Monitor]) -> ReconcileTxn {
        let normalizedMonitors = newMonitors.isEmpty ? [Monitor.fallback()] : newMonitors
        let snapshot = reconcileSnapshot()
        let topologyResolutionContext = monitorResolutionContext(for: normalizedMonitors)
        let topologyPlan = plannedTopologyChange(
            to: normalizedMonitors,
            snapshot: snapshot,
            topologyResolutionContext: topologyResolutionContext
        )
        let event = WMEvent.topologyChanged(
            displays: topologyResolutionContext.topologyProfile.displays,
            source: .workspaceManager
        )

        let previousPlacements = scriptWorkspaceMoveObserver?.catalogPlacements(in: self)
        let txn = commitWorldEvent(
            event,
            monitors: normalizedMonitors,
            resolvePlan: { plan, _, _ in
                var plan = plan
                plan.topologyTransition = TopologyTransitionPlan(
                    previousMonitors: topologyPlan.previousMonitors,
                    newMonitors: topologyPlan.newMonitors,
                    visibleAssignments: topologyPlan.visibleAssignments,
                    disconnectedVisibleWorkspaceCache: topologyPlan.disconnectedVisibleWorkspaceCache,
                    interactionMonitorId: topologyPlan.interactionMonitorId,
                    previousInteractionMonitorId: topologyPlan.previousInteractionMonitorId,
                    refreshRestoreIntents: topologyPlan.refreshRestoreIntents
                )
                plan.notes.append("restore_refresh=topology")
                if !topologyPlan.notes.isEmpty {
                    plan.notes.append(contentsOf: topologyPlan.notes)
                }
                return self.applyActionPlan(plan, to: nil)
            }
        )
        if txn.plan.mutatesRuntimeState || eventRequiresRuntimeInvalidation(event) {
            noteInvalidation(for: event)
        }
        withCatalogObserver(.topology) {
            $0.topologyCommitted(previous: topologyPlan.previousMonitors, current: topologyPlan.newMonitors, in: self)
        }
        if let previousPlacements {
            withCatalogObserver(.move) { $0.catalogCommitted(previous: previousPlacements, in: self) }
        }
        return txn
    }

    private func plannedTopologyChange(
        to normalizedMonitors: [Monitor],
        snapshot: ReconcileSnapshot,
        topologyResolutionContext: MonitorResolutionContext
    ) -> MonitorTopologyRestorePlan {
        let runtimeOverrideReconnectPreferences = runtimeOverrideReconnectAssignments(
            previousMonitors: monitors,
            newMonitors: normalizedMonitors
        )
        return MonitorTopologyRestorePlanner.plan(
            .init(
                snapshot: snapshot,
                previousMonitors: monitors,
                newMonitors: normalizedMonitors,
                visibleWorkspaceMap: activeVisibleWorkspaceMap(),
                disconnectedVisibleWorkspaceCache: disconnectedWorkspaceAssignments,
                runtimeOverrideReconnectPreferences: runtimeOverrideReconnectPreferences,
                interactionMonitorId: focusSessionSnapshot.interactionMonitorId,
                previousInteractionMonitorId: focusSessionSnapshot.previousInteractionMonitorId,
                workspaceExists: { [weak self] workspaceId in
                    self?.descriptor(for: workspaceId) != nil
                },
                homeMonitorId: { [weak self] workspaceId, monitors in
                    guard let self else { return nil }
                    let context = monitors == topologyResolutionContext.monitors
                        ? topologyResolutionContext
                        : self.monitorResolutionContext(for: monitors)
                    return self.homeMonitor(for: workspaceId, context: context)?.id
                },
                effectiveMonitorId: { [weak self] workspaceId, monitors in
                    guard let self else { return nil }
                    let context = monitors == topologyResolutionContext.monitors
                        ? topologyResolutionContext
                        : self.monitorResolutionContext(for: monitors)
                    return self.effectiveMonitor(for: workspaceId, context: context)?.id
                }
            )
        )
    }

    func applyMonitorConfigurationChange(_ newMonitors: [Monitor]) {
        _ = recordTopologyChange(to: newMonitors)
    }
}
