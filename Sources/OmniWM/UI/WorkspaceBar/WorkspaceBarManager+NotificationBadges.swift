// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WorkspaceBarManager {
    func updateNotificationBadgeTargets(_ bars: [DesiredBarSurface]) {
        let scratchpadIcons = shellHost?.config.scratchpadIcons ?? 0
        notificationBadgeTargetsByMonitor = Dictionary(uniqueKeysWithValues: bars.map { bar in
            let snapshot = bar.visible ? barsByMonitor[bar.monitor.id]?.model.snapshot ?? bar.snapshot : bar.snapshot
            var bundleIDs: Set<String> = []
            let items = snapshot.items
            for index in items.indices {
                Self.insertBundleIDs(of: items[index].tiledWindows, into: &bundleIDs)
                Self.insertBundleIDs(of: items[index].floatingWindows, into: &bundleIDs)
            }
            let compacted = shellCompactedScratchpads[bar.monitor.id] ?? []
            let scratchpads = snapshot.scratchpads
            for index in scratchpads.indices
                where scratchpads[index].presentation == .expanded && !compacted.contains(scratchpads[index].index)
            {
                Self.insertBundleIDs(of: scratchpads[index].windows, limit: scratchpadIcons, into: &bundleIDs)
            }
            return (bar.monitor.id, bundleIDs)
        })
        syncNotificationBadges()
    }

    private static func insertBundleIDs(
        of windows: [WorkspaceBarWindowItem],
        limit: Int = .max,
        into bundleIDs: inout Set<String>
    ) {
        for index in windows.indices.prefix(limit) {
            if let bundleID = windows[index].bundleId { bundleIDs.insert(bundleID.lowercased()) }
        }
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
