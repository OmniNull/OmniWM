// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

enum MonitorSetupSystemSettings {
    static let displaysURLString = "x-apple.systempreferences:com.apple.preference.displays"

    @MainActor
    static func openDisplays() {
        guard let url = URL(string: displaysURLString) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct MonitorSetupMacOSArrangementStep: View {
    let liveMonitors: [Monitor]
    let animationsEnabled: Bool
    @Binding var confirmedMacOSArrangement: Bool

    private var liveDisplayLabels: [Monitor.ID: MonitorDisplayLabel] {
        MonitorSettingsTabModel.displayLabels(for: liveMonitors)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MonitorSetupExplanation(
                title: String(localized: "First, make a technical staircase"),
                text: String(
                    localized: "This macOS arrangement is intentionally different from your desk. It keeps OmniWM’s hidden windows from appearing on another display."
                )
            )

            MonitorSetupStaircaseIllustration(
                displayCount: max(2, liveMonitors.count),
                animationsEnabled: animationsEnabled
            )

            MonitorSetupInstructionRow(
                number: 1,
                title: String(localized: "Put your physically largest or widest display at the bottom"),
                detail: String(localized: "OmniWM cannot measure physical screen size, so choose the display yourself.")
            )
            MonitorSetupInstructionRow(
                number: 2,
                title: String(localized: "Place the next display on its top-right corner"),
                detail: String(localized: "Its bottom-left corner should touch the lower display’s top-right corner.")
            )
            MonitorSetupInstructionRow(
                number: 3,
                title: String(localized: "Continue upward and to the right"),
                detail: String(localized: "For equal-size displays, any order is fine.")
            )

            MonitorSetupCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your current macOS arrangement")
                            .font(.headline)
                        Text("This preview updates when you return from Display Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Display Settings", action: MonitorSetupSystemSettings.openDisplays)
                }

                if liveMonitors.isEmpty {
                    ContentUnavailableView(
                        "No Displays Detected",
                        systemImage: "display.trianglebadge.exclamationmark",
                        description: Text("Reconnect your displays, then return to this guide.")
                    )
                    .frame(height: 170)
                } else {
                    MonitorArrangementCanvas(
                        monitors: liveMonitors,
                        displayLabels: liveDisplayLabels,
                        height: 180
                    )
                }

                if let warning = MonitorSetupMacOSAssessment.warning(for: liveMonitors) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                Toggle(isOn: $confirmedMacOSArrangement) {
                    Text("I arranged the displays like the staircase above")
                }
                .disabled(liveMonitors.count < 2)
                .accessibilityHint("Confirms the physical size and corner placement that OmniWM cannot verify.")
            }
        }
    }
}

struct MonitorSetupPhysicalArrangementStep: View {
    @Binding var draft: MonitorSetupDraft
    @Binding var selectedMonitor: Monitor.ID?
    let draftMonitors: [Monitor]
    let liveMonitors: [Monitor]
    let identificationOverlayController: MonitorIdentificationOverlayController

    private var draftDisplayLabels: [Monitor.ID: MonitorDisplayLabel] {
        MonitorSettingsTabModel.displayLabels(for: draftMonitors)
    }

    private var displayNumbers: [Monitor.ID: Int] {
        Dictionary(uniqueKeysWithValues: draftMonitors.enumerated().map { ($0.element.id, $0.offset + 1) })
    }

    private var routingTiles: [RoutingArrangementCanvas.Tile] {
        draftMonitors.compactMap { monitor in
            guard let cell = draft.cell(for: monitor.id) else { return nil }
            return RoutingArrangementCanvas.Tile(
                id: monitor.id,
                column: cell.column,
                row: cell.row,
                displayLabel: draftDisplayLabels[monitor.id],
                fallbackName: monitor.name,
                isMain: monitor.isMain,
                identifierNumber: displayNumbers[monitor.id]
            )
        }
    }

    private var routingRows: [RoutingAccessibleEditor.Row] {
        draftMonitors.map { monitor in
            let number = displayNumbers[monitor.id] ?? 0
            let name = draftDisplayLabels[monitor.id]?.accessibilityName ?? monitor.name
            return RoutingAccessibleEditor.Row(id: monitor.id, name: String(localized: "Display \(number), \(name)"))
        }
    }

    private var routingReadiness: MonitorSetupDraft.Readiness {
        draft.readiness(for: liveMonitors)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MonitorSetupExplanation(
                title: String(localized: "Now show OmniWM where the displays really are"),
                text: String(
                    localized: "macOS keeps the technical staircase. In OmniWM, arrange the numbered tiles to match which display is left, right, above, or below on your desk."
                )
            )

            HStack(spacing: 12) {
                MonitorSetupMapLabel(
                    icon: "macwindow",
                    title: "macOS",
                    detail: String(localized: "Technical staircase")
                )
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                MonitorSetupMapLabel(
                    icon: "display.2",
                    title: "OmniWM",
                    detail: String(localized: "Your real desk")
                )
            }
            .frame(maxWidth: .infinity)

            MonitorSetupCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("OmniWM routing arrangement")
                            .font(.headline)
                        Text("Drag tiles, or use the arrow buttons below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show Numbers on Screens") {
                        identificationOverlayController.show(
                            monitors: draftMonitors,
                            displayLabels: draftDisplayLabels
                        )
                    }
                    .disabled(routingReadiness == .monitorConfigurationChanged)
                    .accessibilityHint("Briefly shows each tile’s number on its physical display.")
                }

                RoutingArrangementCanvas(
                    tiles: routingTiles,
                    selected: selectedMonitor,
                    onSelect: { selectedMonitor = $0 },
                    onPlace: { monitorID, column, row in
                        draft.place(monitorID, at: .init(column: column, row: row))
                    },
                    height: 230
                )

                RoutingAccessibleEditor(
                    rows: routingRows,
                    onMove: { monitorID, direction in
                        draft.move(monitorID, direction: direction)
                    }
                )

                routingStatus
            }

            Text(
                "A display can be farther away in the grid, but every display must be reachable through a shared row or column. A diagonal tile by itself is disconnected."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var routingStatus: some View {
        switch routingReadiness {
        case .ready:
            Label("Every display is connected", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .disconnected:
            Label(
                "Move the tiles so every display connects through a left, right, up, or down path.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.orange)
        case .monitorConfigurationChanged:
            EmptyView()
        }
    }
}

private struct MonitorSetupInstructionRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number.formatted())
                .font(.callout.bold())
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MonitorSetupMapLabel: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct MonitorSetupStaircaseIllustration: View {
    let displayCount: Int
    let animationsEnabled: Bool

    @State private var arranged = false
    @State private var replayID = 0

    var body: some View {
        MonitorSetupCard {
            GeometryReader { proxy in
                let transition = MonitorSetupStaircaseGeometry.transition(
                    displayCount: displayCount,
                    in: proxy.size,
                    padding: 8
                )
                let rects = !animationsEnabled || arranged
                    ? transition.staircase
                    : transition.sideBySide

                ZStack(alignment: .topLeading) {
                    ForEach(rects.indices, id: \.self) { index in
                        MonitorSetupExampleDisplay(index: index, count: rects.count)
                            .frame(width: rects[index].width, height: rects[index].height)
                            .position(x: rects[index].midX, y: rects[index].midY)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(height: 180)
            .accessibilityHidden(true)
            .task(id: replayID) {
                guard animationsEnabled else { return }
                arranged = false
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 1.0)) {
                    arranged = true
                }
            }

            HStack {
                Text(
                    "The largest example stays at the bottom; every smaller display continues from the top-right corner."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Replay") {
                    replayID += 1
                }
                .controlSize(.small)
                .disabled(!animationsEnabled)
            }
        }
    }
}

private struct MonitorSetupExampleDisplay: View {
    let index: Int
    let count: Int

    private var color: Color {
        let colors: [Color] = [.accentColor, .indigo, .mint, .orange, .pink, .cyan]
        return colors[index % colors.count]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.75), color.opacity(0.28)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.white.opacity(0.35))
            Text(index == 0 ? String(localized: "Largest") : "\(index + 1)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(.white.opacity(0.6))
                .frame(width: max(10, 30 - CGFloat(index) * 3), height: 2)
                .padding(.top, 4)
        }
    }
}

enum MonitorSetupMacOSAssessment {
    static func warning(for monitors: [Monitor]) -> String? {
        guard monitors.count > 1 else {
            return String(localized: "Connect at least two displays to continue.")
        }
        guard monitors.allSatisfy({ $0.frame.width > 1 && $0.frame.height > 1 }) else {
            return String(localized: "macOS is still updating the display layout. Wait a moment and try again.")
        }

        for firstIndex in monitors.indices {
            for secondIndex in monitors.indices where secondIndex > firstIndex {
                let first = monitors[firstIndex].frame
                let second = monitors[secondIndex].frame
                let overlap = first.intersection(second)
                if overlap.width > 1 && overlap.height > 1 {
                    return String(
                        localized: "Two displays overlap or may be mirrored. Turn off mirroring before continuing."
                    )
                }

                let xOverlap = min(first.maxX, second.maxX) - max(first.minX, second.minX)
                let yOverlap = min(first.maxY, second.maxY) - max(first.minY, second.minY)
                if xOverlap > 1 || yOverlap > 1 {
                    return String(
                        localized: "Some displays still share an edge. The recommended staircase touches only at the corners."
                    )
                }
            }
        }
        return nil
    }
}
