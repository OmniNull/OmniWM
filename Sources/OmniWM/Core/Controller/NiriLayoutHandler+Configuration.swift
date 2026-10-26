// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension NiriLayoutHandler {
    func enableNiriLayout(
        centerFocusedColumn: CenterFocusedColumn = .never,
        alwaysCenterSingleColumn: Bool = false
    ) {
        guard let controller else { return }
        let engine = NiriLayoutEngine()
        engine.centerFocusedColumn = centerFocusedColumn
        engine.alwaysCenterSingleColumn = alwaysCenterSingleColumn
        engine.renderStyle.tabIndicatorWidth = controller.tabRailStyle.reservedWidth
        engine.animationClock = controller.animationClock
        controller.niriEngine = engine

        syncMonitorsToNiriEngine()

        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
    }

    func syncMonitorsToNiriEngine() {
        guard let controller, let engine = controller.niriEngine else { return }

        let currentMonitors = controller.workspaceManager.monitors
        var orientations: [Monitor.ID: Monitor.Orientation] = [:]
        orientations.reserveCapacity(currentMonitors.count)
        for monitor in currentMonitors {
            orientations[monitor.id] = controller.settings.monitors.effectiveOrientation(for: monitor)
        }
        let workspaceAssignments: [(workspaceId: WorkspaceDescriptor.ID, monitor: Monitor)] =
            controller.workspaceManager.workspaces.compactMap { workspace in
                guard let monitor = controller.workspaceManager.monitor(for: workspace.id) else { return nil }
                return (workspaceId: workspace.id, monitor: monitor)
            }
        controller.workspaceManager.withEngineMutationScope {
            engine.updateMonitors(currentMonitors, orientations: orientations)
        }
        refreshResolvedMonitorSettings()
        controller.workspaceManager.withEngineMutationScope {
            engine.syncWorkspaceAssignments(workspaceAssignments, orientations: orientations)
        }
    }

    func refreshResolvedMonitorSettings(rebalanceChangedSpans: Bool = false) {
        guard let controller, let engine = controller.niriEngine else { return }

        var changedSpanMonitors: [Monitor.ID] = []
        controller.workspaceManager.withEngineMutationScope {
            for monitor in controller.workspaceManager.monitors {
                let resolved = controller.settings.niri.resolved(for: monitor)
                if rebalanceChangedSpans,
                   engine.effectiveSettings(for: monitor.id).defaultContainerPrimarySpan
                   != resolved.defaultContainerPrimarySpan
                {
                    changedSpanMonitors.append(monitor.id)
                }
                _ = engine.ensureMonitor(
                    for: monitor.id,
                    monitor: monitor,
                    orientation: controller.settings.monitors.effectiveOrientation(for: monitor)
                )
                engine.updateMonitorSettings(resolved, for: monitor.id)
            }
        }
        for monitorId in changedSpanMonitors {
            balanceSizesAllWorkspaces(on: monitorId)
        }
    }

    func updateNiriConfig(
        visibleContainerCount: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowFit: SingleWindowFit? = nil,
        edgeOverscroll: NiriEdgeOverscroll? = nil,
        containerPrimarySpanPresets: [Double]? = nil,
        defaultContainerPrimarySpan: Double?? = nil
    ) {
        guard let controller else { return }
        controller.workspaceManager.withEngineMutationScope {
            controller.niriEngine?.updateConfiguration(
                visibleContainerCount: visibleContainerCount,
                infiniteLoop: infiniteLoop,
                centerFocusedColumn: centerFocusedColumn,
                alwaysCenterSingleColumn: alwaysCenterSingleColumn,
                singleWindowFit: singleWindowFit,
                edgeOverscroll: edgeOverscroll,
                presetContainerPrimarySpans: containerPrimarySpanPresets?.map { .proportion($0) },
                defaultContainerPrimarySpan: defaultContainerPrimarySpan.map { $0.map { CGFloat($0) } }
            )
        }
        refreshResolvedMonitorSettings(rebalanceChangedSpans: defaultContainerPrimarySpan != nil)
        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
    }
}
