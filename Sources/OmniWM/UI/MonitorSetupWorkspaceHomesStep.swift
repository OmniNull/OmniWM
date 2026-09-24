// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

struct MonitorSetupWorkspaceHomesStep: View {
    @Binding var draft: MonitorSetupDraft
    let draftMonitors: [Monitor]
    let liveMonitors: [Monitor]

    private var draftDisplayLabels: [Monitor.ID: MonitorDisplayLabel] {
        MonitorSettingsTabModel.displayLabels(for: draftMonitors)
    }

    private var displayNumbers: [Monitor.ID: Int] {
        Dictionary(uniqueKeysWithValues: draftMonitors.enumerated().map { ($0.element.id, $0.offset + 1) })
    }

    private var uncoveredMonitors: [Monitor] {
        draft.uncoveredMonitors(in: liveMonitors)
    }

    private var hasWorkspaceCoverage: Bool {
        draft.hasWorkspaceCoverage(in: liveMonitors)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MonitorSetupExplanation(
                title: String(localized: "Make every display a window destination"),
                text: String(
                    localized: "Moving a window to another display requires a workspace there. Assign at least one workspace to every connected display before finishing setup."
                )
            )

            MonitorSetupCard {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace home monitors")
                        .font(.headline)
                    Text("You can change these later in Workspaces settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    ForEach(draft.workspaceConfigurations) { configuration in
                        MonitorSetupWorkspaceRow(
                            configuration: configuration,
                            monitorAssignment: monitorAssignmentBinding(for: configuration.id),
                            connectedMonitors: liveMonitors,
                            canRemove: draft.isDraftCreatedWorkspace(configuration.id),
                            onRemove: {
                                draft.removeDraftCreatedWorkspace(configuration.id)
                            }
                        )
                    }
                }
            }

            MonitorSetupCard {
                if hasWorkspaceCoverage {
                    Label("Every display has a workspace", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                } else {
                    Label(
                        "Add or reassign a workspace for each display below",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.headline)
                    .foregroundStyle(.orange)

                    ForEach(uncoveredMonitors, id: \.id) { monitor in
                        Button {
                            draft.addWorkspace(for: monitor)
                        } label: {
                            Label(
                                "Add Workspace to \(displayName(for: monitor))",
                                systemImage: "plus.circle"
                            )
                        }
                    }
                }
            }
        }
    }

    private func displayName(for monitor: Monitor) -> String {
        let number = displayNumbers[monitor.id] ?? 0
        let name = draftDisplayLabels[monitor.id]?.accessibilityName ?? monitor.name
        return String(localized: "Display \(number), \(name)")
    }

    private func monitorAssignmentBinding(
        for workspaceID: WorkspaceConfiguration.ID
    ) -> Binding<MonitorAssignment> {
        Binding(
            get: { draft.monitorAssignment(for: workspaceID) ?? .main },
            set: { draft.setMonitorAssignment($0, for: workspaceID) }
        )
    }
}

private struct MonitorSetupWorkspaceRow: View {
    let configuration: WorkspaceConfiguration
    @Binding var monitorAssignment: MonitorAssignment
    let connectedMonitors: [Monitor]
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Workspace \(configuration.name)")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if configuration.effectiveDisplayName != configuration.name {
                    Text(configuration.effectiveDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 110, alignment: .leading)

            Spacer(minLength: 12)

            WorkspaceHomeMonitorPicker(
                selection: $monitorAssignment,
                connectedMonitors: connectedMonitors
            )
            .labelsHidden()
            .frame(width: 260)
            .accessibilityLabel("Home monitor for workspace \(configuration.name)")

            if canRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove Workspace \(configuration.name)", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove workspace \(configuration.name)")
                .help("Remove this newly added workspace")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
