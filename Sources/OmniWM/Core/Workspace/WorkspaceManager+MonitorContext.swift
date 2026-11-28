// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func monitorResolutionContext() -> MonitorResolutionContext {
        let projections = projections
        return MonitorResolutionContext(
            monitors: monitors,
            sortedMonitors: projections.sortedMonitors(),
            topologyProfile: projections.currentTopologyProfile(),
            configuredWorkspaceNames: projections.configuredWorkspaceNameSet(),
            monitorDescriptionByWorkspaceName: projections.monitorDescriptionByWorkspaceName(),
            monitorRanking: settings.monitors.ranking
        )
    }

    func monitorResolutionContext(for monitors: [Monitor]) -> MonitorResolutionContext {
        if monitors == self.monitors {
            return monitorResolutionContext()
        }
        let sortedMonitors = Monitor.sortedByPosition(monitors)
        return MonitorResolutionContext(
            monitors: monitors,
            sortedMonitors: sortedMonitors,
            topologyProfile: TopologyProfile(sortedMonitors: sortedMonitors),
            configuredWorkspaceNames: configuredWorkspaceNameSet(),
            monitorDescriptionByWorkspaceName: monitorDescriptionByWorkspaceName(),
            monitorRanking: settings.monitors.ranking
        )
    }
}
