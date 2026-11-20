// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension WorkspaceBarManager {
    func barAppearance(for resolved: ResolvedBarSettings) -> NSAppearance? {
        usesDarkPalette(resolved) ? NSAppearance(named: .darkAqua) : NSApplication.shared.appearance
    }

    func usesDarkPalette(_ resolved: ResolvedBarSettings) -> Bool {
        resolved.notchMode == .fillLeftOfNotch && menuBarIsDark()
    }

    func refreshMenuBarAppearance() {
        guard let settings = controller?.settings else { return }
        for instance in barsByMonitor.values {
            instance.applyAppearance(barAppearance(for: settings.workspaceBar.resolved(for: instance.monitor)))
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
