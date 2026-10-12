// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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
            for scratchpad in snapshot.scratchpads where scratchpad.presentation == .expanded {
                for window in scratchpad.windows.prefix(WorkspaceBarScratchpadLayout.maximumVisibleAppIcons) {
                    if let bundleID = window.bundleId { bundleIDs.insert(bundleID.lowercased()) }
                }
            }
            return (bar.monitor.id, bundleIDs)
        })
        syncNotificationBadges()
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
        notificationBadges.configure(
            mode: settings.notificationBadges,
            interval: settings.notificationBadgeRefreshIntervalSeconds,
            bundleIDs: targets
        )
    }
}
