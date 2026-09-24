// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct MonitorDisplayLabel: Equatable {
    let name: String
    let duplicateIndex: Int?

    var badgeText: String? {
        duplicateIndex.map { "#\($0)" }
    }

    var accessibilityName: String {
        if let duplicateIndex {
            return String(localized: "\(name), duplicate \(duplicateIndex)")
        }
        return name
    }
}

enum MonitorSettingsTabModel {
    enum RoutingSource: Equatable {
        case exact
        case inherited
        case macOS
    }

    struct RoutingEditorLayout {
        let settings: [MonitorRoutingSettings]
        let source: RoutingSource

        var usesMacOSFallback: Bool {
            source == .macOS && !settings.isEmpty
        }
    }

    static func routingEditorLayout(
        arrangements: [MonitorArrangement],
        monitors: [Monitor]
    ) -> RoutingEditorLayout {
        if let index = MonitorRouting.arrangementIndex(for: monitors, in: arrangements),
           let completeLayout = MonitorRouting.completeLayout(arrangements[index].monitors, for: monitors)
        {
            return RoutingEditorLayout(
                settings: completeLayout,
                source: arrangements[index].monitors.count == monitors.count ? .exact : .inherited
            )
        }

        return RoutingEditorLayout(
            settings: MonitorRouting.seedLayout(from: monitors),
            source: .macOS
        )
    }

    static func routingSettingsAfterEdit(
        monitors: [Monitor],
        cells: [Monitor.ID: (column: Int, row: Int)]
    ) -> [MonitorRoutingSettings] {
        monitors.compactMap { monitor in
            guard let cell = cells[monitor.id] else { return nil }
            return MonitorRoutingSettings(
                monitorName: monitor.name,
                monitorDisplayUUID: monitor.displayUUID,
                monitorDisplayId: monitor.displayId,
                gridColumn: cell.column,
                gridRow: cell.row
            )
        }
    }

    static func shouldSeedRouting(
        arrangements: [MonitorArrangement],
        monitors: [Monitor]
    ) -> Bool {
        !monitors.isEmpty && MonitorRouting.arrangementIndex(for: monitors, in: arrangements) == nil
    }

    static func sortedMonitors(_ monitors: [Monitor]) -> [Monitor] {
        Monitor.sortedByPosition(monitors)
    }

    static func normalizedSelection(_ selectedMonitor: Monitor.ID?, monitors: [Monitor]) -> Monitor.ID? {
        guard !monitors.isEmpty else { return nil }

        if let selectedMonitor,
           monitors.contains(where: { $0.id == selectedMonitor })
        {
            return selectedMonitor
        }

        return monitors.first?.id
    }

    static func displayLabels(for monitors: [Monitor]) -> [Monitor.ID: MonitorDisplayLabel] {
        let sorted = sortedMonitors(monitors)
        let totals = sorted.reduce(into: [String: Int]()) { counts, monitor in
            counts[monitor.name, default: 0] += 1
        }
        var nextIndexByName: [String: Int] = [:]
        var labels: [Monitor.ID: MonitorDisplayLabel] = [:]

        for monitor in sorted {
            nextIndexByName[monitor.name, default: 0] += 1
            let total = totals[monitor.name, default: 0]
            let duplicateIndex = total > 1 ? nextIndexByName[monitor.name] : nil
            labels[monitor.id] = MonitorDisplayLabel(name: monitor.name, duplicateIndex: duplicateIndex)
        }

        return labels
    }
}

extension Monitor.Orientation {
    var displayName: String {
        switch self {
        case .horizontal: String(localized: "Horizontal")
        case .vertical: String(localized: "Vertical")
        }
    }
}
