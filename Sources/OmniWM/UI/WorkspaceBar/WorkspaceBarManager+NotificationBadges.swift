// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension WorkspaceBarManager {
    func updateNotificationBadgeTargets(_ bars: [DesiredBarSurface]) {
        notificationBadgeTargetsByMonitor = Dictionary(uniqueKeysWithValues: bars.map { bar in
            let snapshot = bar.visible ? barsByMonitor[bar.monitor.id]?.model.snapshot ?? bar.snapshot : bar.snapshot
            var bundleIDs: Set<String> = []
            for item in snapshot.items {
                for window in item.tiledWindows + item.floatingWindows {
                    if let bundleID = window.bundleId { bundleIDs.insert(bundleID.lowercased()) }
                }
            }
            let compacted = shellCompactedScratchpads[bar.monitor.id] ?? []
            for scratchpad in snapshot.scratchpads
                where scratchpad.presentation == .expanded && !compacted.contains(scratchpad.index)
            {
                for window in scratchpad.windows.prefix(WorkspaceBarScratchpadLayout.maximumVisibleAppIcons) {
                    if let bundleID = window.bundleId { bundleIDs.insert(bundleID.lowercased()) }
                }
            }
            return (bar.monitor.id, bundleIDs)
        })
        syncNotificationBadges()
    }

    func setShellBadgeDemand(_ demanded: Bool) {
        guard shellBadgeDemand != demanded else { return }
        shellBadgeDemand = demanded
        syncNotificationBadges()
    }

    func publishShellBadges() {
        guard let feed = shellHost?.feed else { return }
        feed.setBadges(notificationBadges.labels.filter { shellBadgeTargets.contains($0.key) })
    }

    func managedBadgeTargets() -> Set<String> {
        guard let controller, controller.hasStartedServices, shellBadgeDemand else { return [] }
        var targets: Set<String> = []
        var resolvedPIDs: Set<pid_t> = []
        for entry in controller.workspaceManager.windowQueries.allEntries() {
            if let bundleID = entry.managedReplacementMetadata?.bundleId {
                if !bundleID.isEmpty { targets.insert(bundleID.lowercased()) }
            } else if resolvedPIDs.insert(entry.pid).inserted,
                      let bundleID = controller.appInfoCache.bundleId(for: entry.pid), !bundleID.isEmpty
            {
                targets.insert(bundleID.lowercased())
            }
        }
        return targets
    }

    func syncNotificationBadges() {
        guard let controller else { return }
        let settings = controller.settings.workspaceBar
        var targets: Set<String> = []
        if controller.hasStartedServices, settings.enabled {
            for monitor in controller.workspaceManager.monitors where settings.resolved(for: monitor).enabled {
                targets.formUnion(notificationBadgeTargetsByMonitor[monitor.id] ?? [])
            }
        }
        let shellTargets = managedBadgeTargets()
        let shellTargetsChanged = shellTargets != shellBadgeTargets
        shellBadgeTargets = shellTargets
        notificationBadges.configure(
            mode: settings.resolvedNotificationBadges,
            interval: settings.resolvedNotificationBadgeRefreshIntervalSeconds,
            bundleIDs: targets,
            shellBundleIDs: shellTargets
        )
        if shellTargetsChanged { publishShellBadges() }
    }
}
