// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension WorkspaceBarManager {
    func barAppearance(for resolved: ResolvedBarSettings, on monitor: Monitor) -> NSAppearance? {
        usesDarkPalette(resolved, on: monitor) ? NSAppearance(named: .darkAqua) : NSApplication.shared.appearance
    }

    func usesDarkPalette(_ resolved: ResolvedBarSettings, on monitor: Monitor) -> Bool {
        !resolved.fullWidth
            && WorkspaceBarGeometry.effectivePosition(for: monitor, resolved: resolved) == .overlappingMenuBar
            && menuBarIsDark
    }

    func refreshMenuBarAppearance() {
        guard let settings = controller?.settings else { return }
        for instance in barsByMonitor.values {
            let resolved = settings.workspaceBar.resolved(for: instance.monitor)
            instance.applyAppearance(barAppearance(for: resolved, on: instance.monitor))
        }
        shellHost?.updateBars()
    }

    func coversNativeMenuBarItems(on monitor: Monitor, resolved: ResolvedBarSettings) -> Bool {
        guard resolved.notchMode == .fillLeftOfNotch, let overflow = menuBarOverflow?.overflow else { return false }
        let frame = WorkspaceBarGeometry.resolve(monitor: monitor, resolved: resolved, isVisible: true)
            .frame(fittingLength: 0, monitor: monitor, resolved: resolved)
        return overflow.covers(ScreenCoordinateSpace.toWindowServer(rect: frame))
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]).map {
            $0 == .darkAqua || $0 == .vibrantDark
        } ?? false
    }
}
