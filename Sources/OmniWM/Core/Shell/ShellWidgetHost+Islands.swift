// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellWidgetHost {
    func updateIslands(_ desired: [DesiredIslandSurface], level: NSWindow.Level) {
        desiredIslands = desired
        islandLevel = level
        let next = islandPlacements(desired)
        if next != islandData {
            islandData = next
            if let popout, popout.key.placement == .island,
               next[popout.key]?.surface?.visible != true
            {
                closePopout()
            }
            for state in widgets.values {
                place(state)
            }
            publishDemand()
        }
        reconcileIslandWindows()
    }

    func islandPlacements(_ desired: [DesiredIslandSurface]) -> [ShellBarKey: ShellBarData] {
        guard let island = config.island else { return [:] }
        var result: [ShellBarKey: ShellBarData] = [:]
        for target in desired where island.includes(target.monitor) {
            let key = ShellBarKey(monitor: target.monitor.id, placement: .island)
            let geometry = ShellIslandGeometry(monitor: target.monitor, size: island.size)
            let data = ShellIslandData(
                monitor: target.monitor,
                geometry: geometry,
                visible: !target.fullscreen || island.fullscreen == .show,
                fullscreen: target.fullscreen,
                focused: focusedIsland == target.monitor.id,
                drag: islandDragMonitor?.state ?? .init(),
                navigation: target.navigation,
                sessionToken: sessionToken
            )
            result[key] = ShellBarData(monitor: target.monitor.name, surface: data)
        }
        return result
    }

    func reconcileIslandWindows() {
        guard let config = config.island, let state = widgets[config.root] else {
            closeIslands()
            return
        }
        for (monitor, island) in islandWindows {
            let key = ShellBarKey(monitor: monitor, placement: .island)
            if islandData[key] == nil || state.instances[key]?.surface !== island.surface {
                releaseIslandFocus(on: monitor, restore: true)
                island.close()
                islandWindows.removeValue(forKey: monitor)
            }
        }
        for target in desiredIslands {
            let monitor = target.monitor
            let key = ShellBarKey(monitor: monitor.id, placement: .island)
            guard let data = islandData[key]?.surface, let instance = state.instances[key] else { continue }
            if let existing = islandWindows[monitor.id], existing.surface.scale != monitor.backingScale {
                releaseIslandFocus(on: monitor.id, restore: true)
                existing.close()
                islandWindows[monitor.id] = nil
                instance.surface = nil
            }
            if islandWindows[monitor.id] == nil {
                _ = surfaceView(widget: state.name, key: key, scale: monitor.backingScale)
                guard let surface = instance.surface else { continue }
                let island = ShellIsland(surface: surface, monitor: monitor, size: config.size)
                islandWindows[monitor.id] = island
                connectIslandInput(island, on: monitor.id)
            }
            islandWindows[monitor.id]?.update(
                monitor: monitor,
                size: config.size,
                visible: data.visible,
                level: islandLevel
            )
        }
        updateIslandInputMonitoring()
        updateIslandDragMonitoring()
    }

    func closeIslands() {
        if let monitor = focusedIsland { releaseIslandFocus(on: monitor, restore: true) }
        for island in islandWindows.values { island.close() }
        islandWindows.removeAll()
        updateIslandInputMonitoring()
        updateIslandDragMonitoring()
    }
}
