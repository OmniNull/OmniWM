// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import SwiftUI

struct MonitorRolesSection: View {
    let settings: MonitorConfigurationSettings
    let connectedMonitors: [Monitor]
    let displayLabels: [Monitor.ID: MonitorDisplayLabel]
    let onRankingChanged: () -> Void

    var body: some View {
        Section("Monitor Roles") {
            ForEach(Array(settings.ranking.enumerated()), id: \.element) { index, entry in
                RankedMonitorRow(
                    role: rankedMonitorRoleLabel(at: index),
                    label: rankedMonitorLabel(for: entry),
                    isConnected: MonitorRanking.isConnected(entry, monitors: connectedMonitors),
                    canMoveUp: index > 0,
                    canMoveDown: index < settings.ranking.count - 1,
                    moveUp: {
                        setMonitorRanking(MonitorRanking.moving(settings.ranking, from: index, by: -1))
                    },
                    moveDown: {
                        setMonitorRanking(MonitorRanking.moving(settings.ranking, from: index, by: 1))
                    },
                    remove: {
                        setMonitorRanking(MonitorRanking.removing(settings.ranking, at: index))
                    }
                )
            }

            Menu("Add Monitor") {
                ForEach(addableRankingEntries, id: \.self) { entry in
                    Button(rankedMonitorLabel(for: entry)) {
                        setMonitorRanking(settings.ranking + [entry])
                    }
                }
            }
            .disabled(addableRankingEntries.isEmpty)

            if settings.ranking.isEmpty {
                SettingsCaption(
                    localized: "Main is the display with the macOS menu bar; Secondary and Tertiary are the next displays in arrangement order. Add displays here to choose the order yourself: the highest-ranked connected display becomes Main, then Secondary, then Tertiary."
                )
            } else {
                SettingsCaption(
                    localized: "Workspaces assigned to Main, Secondary, or Tertiary follow this order using only the displays that are connected. Unranked displays follow after the ranked ones, and the Quake terminal's Main Monitor option uses the same Main."
                )
            }
        }
    }

    private func rankedMonitorRoleLabel(at index: Int) -> String {
        let ranks = MonitorRanking.effectiveRanks(ranking: settings.ranking, monitors: connectedMonitors)
        guard ranks.indices.contains(index), let rank = ranks[index] else {
            return String(localized: "No role")
        }
        return MonitorRanking.roleName(forRank: rank)
    }

    private var addableRankingEntries: [OutputId] {
        MonitorRanking.addable(connected: connectedMonitors, ranking: settings.ranking)
    }

    private func rankedMonitorLabel(for entry: OutputId) -> String {
        guard let monitor = MonitorRanking.resolve(entry, in: connectedMonitors),
              let label = displayLabels[monitor.id]
        else { return entry.name }
        return label.badgeText.map { "\(label.name) \($0)" } ?? label.name
    }

    private func setMonitorRanking(_ ranking: [OutputId]) {
        settings.ranking = ranking
        onRankingChanged()
    }
}

private struct RankedMonitorRow: View {
    let role: String
    let label: String
    let isConnected: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(role)
                .foregroundStyle(.secondary)
                .frame(minWidth: 80, alignment: .leading)
            Text(label)
            if !isConnected {
                Text("(Disconnected)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: moveUp) {
                Image(systemName: "chevron.up")
            }
            .disabled(!canMoveUp)
            .accessibilityLabel("Move \(label) Up")
            Button(action: moveDown) {
                Image(systemName: "chevron.down")
            }
            .disabled(!canMoveDown)
            .accessibilityLabel("Move \(label) Down")
            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle")
            }
            .accessibilityLabel("Remove \(label)")
        }
        .buttonStyle(.borderless)
    }
}
