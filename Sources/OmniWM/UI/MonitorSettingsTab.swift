// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct MonitorSettingsTab: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let navigation: SettingsNavigationModel

    @State private var selectedMonitor: Monitor.ID?
    @State private var connectedMonitors: [Monitor] = Monitor.current()
    @State private var isMonitorSetupPresented = false

    private var sortedMonitors: [Monitor] {
        MonitorSettingsTabModel.sortedMonitors(connectedMonitors)
    }

    private var displayLabels: [Monitor.ID: MonitorDisplayLabel] {
        MonitorSettingsTabModel.displayLabels(for: sortedMonitors)
    }

    private var effectiveSelectedMonitorID: Monitor.ID? {
        MonitorSettingsTabModel.normalizedSelection(selectedMonitor, monitors: sortedMonitors)
    }

    private var selectedConnectedMonitor: Monitor? {
        guard let monitorID = effectiveSelectedMonitorID else { return nil }
        return sortedMonitors.first(where: { $0.id == monitorID })
    }

    private var routingEditorLayout: MonitorSettingsTabModel.RoutingEditorLayout {
        MonitorSettingsTabModel.routingEditorLayout(
            arrangements: settings.monitors.arrangements,
            monitors: sortedMonitors
        )
    }

    private var routingTiles: [RoutingArrangementCanvas.Tile] {
        let layout = routingEditorLayout.settings
        return zip(sortedMonitors, layout).map { monitor, entry in
            RoutingArrangementCanvas.Tile(
                id: monitor.id,
                column: entry.gridColumn,
                row: entry.gridRow,
                displayLabel: displayLabels[monitor.id],
                fallbackName: monitor.name,
                isMain: monitor.isMain
            )
        }
    }

    private var routingRows: [RoutingAccessibleEditor.Row] {
        sortedMonitors.map { monitor in
            RoutingAccessibleEditor.Row(
                id: monitor.id,
                name: displayLabels[monitor.id]?.accessibilityName ?? monitor.name
            )
        }
    }

    private var routingNeighborPreview: [(direction: String, name: String)] {
        guard let monitor = selectedConnectedMonitor else { return [] }
        let directions: [(String, Direction)] = [
            (String(localized: "Left"), .left),
            (String(localized: "Right"), .right),
            (String(localized: "Up"), .up),
            (String(localized: "Down"), .down)
        ]
        return directions.map { label, direction in
            let neighbor = routingNeighbor(of: monitor, direction)
            let name = neighbor.flatMap { displayLabels[$0.id]?.name } ?? neighbor?.name ?? String(localized: "None")
            return (label, name)
        }
    }

    private var routingModeSelection: Binding<MonitorRoutingMode> {
        Binding(
            get: { settings.monitors.routingMode },
            set: { mode in
                settings.monitors.routingMode = mode
                guard mode == .custom else { return }
                ensureRoutingSeeded()
            }
        )
    }

    var body: some View {
        SettingsPage(
            subtitle: String(
                localized: "macOS controls where windows are placed. OmniWM can use a separate map that matches how your displays are actually arranged on your desk."
            )
        ) {
            MonitorSetupLaunchSection(isComplete: settings.monitorSetupStatus == .completed) {
                isMonitorSetupPresented = true
            }

            Section("macOS Arrangement") {
                if sortedMonitors.isEmpty {
                    Text("No monitors detected.")
                        .foregroundStyle(.secondary)
                } else {
                    MonitorArrangementCanvas(
                        monitors: sortedMonitors,
                        displayLabels: displayLabels,
                        selected: effectiveSelectedMonitorID,
                        onSelect: { selectedMonitor = $0 }
                    )
                    SettingsCaption(
                        localized: "This is the technical macOS map used for actual window placement. For multiple displays, the setup guide shows how to arrange them as a corner-to-corner staircase."
                    )
                }
            }

            Section("OmniWM Routing Arrangement") {
                Picker("Arrangement", selection: routingModeSelection) {
                    Text("Use macOS Arrangement").tag(MonitorRoutingMode.macOS)
                    Text("Custom Arrangement").tag(MonitorRoutingMode.custom)
                }
                .pickerStyle(.segmented)

                if settings.monitors.routingMode == .custom {
                    if routingTiles.isEmpty {
                        Text(
                            connectedMonitors.isEmpty ?
                                String(localized: "No monitors detected.") :
                                String(localized: "Custom routing does not match the connected monitors.")
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        RoutingArrangementCanvas(
                            tiles: routingTiles,
                            selected: effectiveSelectedMonitorID,
                            onSelect: { selectedMonitor = $0 },
                            onPlace: { placeRouting($0, column: $1, row: $2) }
                        )

                        if !routingNeighborPreview.isEmpty {
                            ForEach(routingNeighborPreview, id: \.direction) { entry in
                                LabeledContent(entry.direction) {
                                    Text(entry.name).foregroundStyle(.secondary)
                                }
                            }
                        }

                        RoutingAccessibleEditor(rows: routingRows, onMove: { moveRouting($0, $1) })
                    }

                    if !sortedMonitors.isEmpty {
                        switch routingEditorLayout.source {
                        case .exact:
                            SettingsCaption(
                                localized: "This arrangement is saved for the connected displays. Changes update only this arrangement."
                            )
                        case .inherited:
                            SettingsCaption(
                                localized: "Using an arrangement saved with additional displays. Editing or resetting saves a separate arrangement for the displays connected now."
                            )
                        case .macOS:
                            SettingsCaption(
                                localized: "No valid saved arrangement covers the connected displays. The macOS arrangement is shown without changing your saved arrangements. Dragging a monitor or using the arrow controls saves an arrangement for these displays."
                            )
                        }
                    }

                    Button("Reset Custom Arrangement to macOS Layout") { seedFromMacOS() }

                    SettingsCaption(
                        localized: "Make this look like your real desk. Displays in the same row or column can exchange focus, windows, and the pointer. OmniWM remembers an arrangement for each set of connected displays. This does not change where macOS places windows."
                    )
                } else {
                    SettingsCaption(
                        localized: "Routing currently follows the technical macOS map. Run the setup guide to create a separate map that matches your desk."
                    )
                }
            }

            MonitorRolesSection(
                settings: settings.monitors,
                connectedMonitors: connectedMonitors,
                displayLabels: displayLabels,
                onRankingChanged: controller.updateWorkspaceConfig
            )

            Section("Cross-Monitor Behavior") {
                Toggle("Focus Across Monitor at Edge", isOn: Bindable(settings.focus).crossesMonitorAtEdge)
                Toggle("Move Window Across Monitor at Edge", isOn: Bindable(settings.focus).moveCrossesMonitorAtEdge)
                Toggle("Follow Window to Monitor", isOn: Bindable(settings.focus).followsWindowToMonitor)
                Toggle(isOn: Bindable(settings.pointer).enabled) {
                    HStack(spacing: 8) {
                        Text("Mouse Warp")
                        MonitorBadge(text: String(localized: "Recommended"))
                    }
                }
                Toggle("Constrain Cursor to Arrangement", isOn: Bindable(settings.pointer).constrainToArrangement)
                    .disabled(!settings.pointer.enabled || settings.monitors.routingMode != .custom)

                LabeledContent("Mouse Warp Margin") {
                    Stepper(value: Bindable(settings.pointer).margin, in: 1 ... 10) {
                        Text("\(settings.pointer.margin) px")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .disabled(!settings.pointer.enabled)

                SettingsCaption(
                    localized: "Mouse Warp moves the pointer across matching display edges using the OmniWM routing arrangement. It is recommended when the macOS displays touch only at their corners."
                )
            }

            Section("Monitor Orientation") {
                if let monitor = selectedConnectedMonitor,
                   let displayLabel = displayLabels[monitor.id]
                {
                    SelectedMonitorDetails(
                        settings: settings,
                        controller: controller,
                        monitor: monitor,
                        displayLabel: displayLabel
                    )
                } else {
                    Text("No monitors detected.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            refreshConnectedMonitors()
            presentRequestedMonitorSetupIfNeeded()
        }
        .onChange(of: navigation.hasPendingMonitorSetupPresentation) { _, pending in
            guard pending else { return }
            presentRequestedMonitorSetupIfNeeded()
        }
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification))
        { _ in
            refreshConnectedMonitors()
        }
        .sheet(isPresented: $isMonitorSetupPresented) {
            MonitorSetupGuide(
                settings: settings,
                controller: controller,
                monitors: sortedMonitors,
                onFinish: { isMonitorSetupPresented = false },
                onSkip: { isMonitorSetupPresented = false }
            )
        }
    }

    private func presentRequestedMonitorSetupIfNeeded() {
        guard navigation.consumeMonitorSetupPresentationRequest() else { return }
        isMonitorSetupPresented = true
    }

    private func refreshConnectedMonitors() {
        let monitors = Monitor.current()
        connectedMonitors = monitors
        selectedMonitor = MonitorSettingsTabModel.normalizedSelection(
            selectedMonitor,
            monitors: MonitorSettingsTabModel.sortedMonitors(monitors)
        )
    }

    private func routingNeighbor(of monitor: Monitor, _ direction: Direction) -> Monitor? {
        switch MonitorRouting.gridAdjacent(
            from: monitor,
            direction: direction,
            layout: routingEditorLayout.settings,
            monitors: sortedMonitors,
            wrapAround: false
        ) {
        case let .monitor(neighbor): neighbor
        case .edge,
             .fallBackToMacOS: nil
        }
    }

    private func ensureRoutingSeeded() {
        guard settings.monitors.routingMode == .custom else { return }
        guard MonitorSettingsTabModel.shouldSeedRouting(
            arrangements: settings.monitors.arrangements,
            monitors: connectedMonitors
        ) else { return }
        seedFromMacOS()
    }

    private func seedFromMacOS() {
        settings.monitors.storeRoutingLayout(MonitorRouting.seedLayout(from: connectedMonitors), for: connectedMonitors)
    }

    private func placeRouting(_ monitorID: Monitor.ID, column: Int, row: Int) {
        let monitors = sortedMonitors
        let layout = routingEditorLayout.settings
        var cells: [Monitor.ID: MonitorSetupDraft.Cell] = [:]
        for (monitor, entry) in zip(monitors, layout) {
            cells[monitor.id] = .init(column: entry.gridColumn, row: entry.gridRow)
        }
        MonitorRoutingGridEditor.place(
            monitorID,
            at: .init(column: column, row: row),
            cells: &cells
        )
        let updated = MonitorSettingsTabModel.routingSettingsAfterEdit(
            monitors: monitors,
            cells: cells.mapValues { (column: $0.column, row: $0.row) }
        )
        settings.monitors.storeRoutingLayout(updated, for: monitors)
    }

    private func moveRouting(_ monitorID: Monitor.ID, _ direction: Direction) {
        let monitors = sortedMonitors
        let layout = routingEditorLayout.settings
        guard let index = monitors.firstIndex(where: { $0.id == monitorID }),
              layout.indices.contains(index)
        else { return }
        let entry = layout[index]
        var column = entry.gridColumn
        var row = entry.gridRow
        switch direction {
        case .left: column -= 1
        case .right: column += 1
        case .up: row -= 1
        case .down: row += 1
        }
        placeRouting(monitorID, column: column, row: row)
    }
}

private struct MonitorBadgeRow: View {
    let displayLabel: MonitorDisplayLabel
    let isMain: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let duplicateBadge = displayLabel.badgeText {
                MonitorBadge(text: duplicateBadge)
            }

            if isMain {
                MonitorBadge(text: String(localized: "Main"))
            }
        }
    }
}

private struct MonitorBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

private struct SelectedMonitorDetails: View {
    @Bindable var settings: SettingsStore
    @Bindable var controller: WMController
    let monitor: Monitor
    let displayLabel: MonitorDisplayLabel
    @State private var rejectedGestureConflict: TrackpadGestureConflict?

    private var orientationOverride: Monitor.Orientation? {
        settings.monitors.orientationSettings(for: monitor)?.orientation
    }

    private var effectiveOrientation: Monitor.Orientation {
        settings.monitors.effectiveOrientation(for: monitor)
    }

    private var gestureConflict: TrackpadGestureConflict? {
        rejectedGestureConflict ?? GestureSettingsValidation.conflict(
            gestures: settings.gestures.export(),
            orientationOverrides: settings.monitors.orientationOverrides,
            monitors: controller.workspaceManager.monitors
        )
    }

    var body: some View {
        LabeledContent("Monitor") {
            HStack(spacing: 8) {
                Text(displayLabel.name)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)

                MonitorBadgeRow(displayLabel: displayLabel, isMain: monitor.isMain)
            }
        }

        LabeledContent("Auto-detected") {
            Text(monitor.autoOrientation.displayName)
                .foregroundStyle(.secondary)
        }

        LabeledContent("Current") {
            Text(effectiveOrientation.displayName)
                .fontWeight(.medium)
        }

        Picker("Orientation Override", selection: Binding(
            get: { orientationOverride },
            set: { newValue in
                updateOrientation(newValue)
            }
        )) {
            Text("Auto").tag(nil as Monitor.Orientation?)
            Text("Horizontal").tag(Monitor.Orientation.horizontal as Monitor.Orientation?)
            Text("Vertical").tag(Monitor.Orientation.vertical as Monitor.Orientation?)
        }
        .pickerStyle(.segmented)

        if orientationOverride != nil {
            Button("Reset to Auto") {
                updateOrientation(nil)
            }
        }

        SettingsCaption(localized: "Vertical monitors scroll windows top-to-bottom instead of left-to-right.")

        if let conflict = gestureConflict {
            Label(conflict.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func updateOrientation(_ orientation: Monitor.Orientation?) {
        rejectedGestureConflict = settings.updateMonitorOrientation(
            orientation,
            for: monitor,
            monitors: controller.workspaceManager.monitors
        )
        guard rejectedGestureConflict == nil else { return }
        controller.updateMonitorOrientations()
    }
}
