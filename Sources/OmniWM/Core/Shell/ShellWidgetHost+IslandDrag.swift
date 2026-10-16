// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

extension ShellWidgetHost {
    func updateIslandDragMonitoring() {
        let demanded = islandWindows.values.contains { $0.panel.isVisible && $0.surface.hasResourceDrops }
        if demanded, islandDragMonitor == nil {
            islandDragMonitor = ShellIslandDragMonitor { [weak self] state in self?.publishIslandDrag(state) }
        }
        islandDragMonitor?.setDemand(demanded)
    }

    func publishIslandDrag(_ drag: ShellIslandDragState) {
        var changed = false
        for key in islandData.keys where islandData[key]?.surface?.drag != drag {
            islandData[key]?.surface?.drag = drag
            changed = true
        }
        if changed, let root = config.island?.root, let state = widgets[root] {
            state.mailbox?.yield(.bars(bars(for: state)))
        }
    }
}
