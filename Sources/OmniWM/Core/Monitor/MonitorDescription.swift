// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum MonitorDescription: Equatable {
    case main
    case secondary
    case tertiary
    case output(OutputId)

    func resolveMonitor(sortedMonitors: [Monitor], ranking: [OutputId] = []) -> Monitor? {
        switch self {
        case .main:
            return rankedMonitor(0, sortedMonitors: sortedMonitors, ranking: ranking)
        case .secondary:
            return rankedMonitor(1, sortedMonitors: sortedMonitors, ranking: ranking)
        case .tertiary:
            return rankedMonitor(2, sortedMonitors: sortedMonitors, ranking: ranking)
        case let .output(output):
            return output.resolveMonitor(in: sortedMonitors)
        }
    }

    private func rankedMonitor(_ rank: Int, sortedMonitors: [Monitor], ranking: [OutputId]) -> Monitor? {
        MonitorRanking.monitor(atRole: rank, ranking: ranking, sortedMonitors: sortedMonitors)
    }
}
