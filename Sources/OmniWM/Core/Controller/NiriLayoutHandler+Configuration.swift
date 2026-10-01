// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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
        engine.updateAccordionStyle(
            padding: CGFloat(controller.settings.niri.accordionPadding),
            axis: controller.settings.niri.accordionAxis
        )
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

    func refreshResolvedMonitorSettings() {
        guard let controller, let engine = controller.niriEngine else { return }

        controller.workspaceManager.withEngineMutationScope {
            for monitor in controller.workspaceManager.monitors {
                _ = engine.ensureMonitor(
                    for: monitor.id,
                    monitor: monitor,
                    orientation: controller.settings.monitors.effectiveOrientation(for: monitor)
                )
                engine.updateMonitorSettings(controller.settings.niri.resolved(for: monitor), for: monitor.id)
            }
        }
    }

    func updateNiriConfig(
        visibleContainerCount: Int? = nil,
        infiniteLoop: Bool? = nil,
        centerFocusedColumn: CenterFocusedColumn? = nil,
        alwaysCenterSingleColumn: Bool? = nil,
        singleWindowFit: SingleWindowFit? = nil,
        containerPrimarySpanPresets: [Double]? = nil,
        defaultContainerPrimarySpan: Double?? = nil,
        accordionPadding: Double? = nil,
        accordionAxis: AccordionAxis? = nil
    ) {
        guard let controller else { return }
        controller.workspaceManager.withEngineMutationScope {
            controller.niriEngine?.updateConfiguration(
                visibleContainerCount: visibleContainerCount,
                infiniteLoop: infiniteLoop,
                centerFocusedColumn: centerFocusedColumn,
                alwaysCenterSingleColumn: alwaysCenterSingleColumn,
                singleWindowFit: singleWindowFit,
                presetContainerPrimarySpans: containerPrimarySpanPresets?.map { .proportion($0) },
                defaultContainerPrimarySpan: defaultContainerPrimarySpan.map { $0.map { CGFloat($0) } },
                accordionPadding: accordionPadding.map { CGFloat($0) },
                accordionAxis: accordionAxis
            )
        }
        refreshResolvedMonitorSettings()
        controller.layoutRefreshController.requestRelayout(reason: .layoutConfigChanged)
    }
}
