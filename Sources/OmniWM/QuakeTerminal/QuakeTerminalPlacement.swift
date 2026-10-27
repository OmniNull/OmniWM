// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
struct QuakeTerminalPlacement {
    private let position: QuakeTerminalPosition
    private let screen: NSScreen
    private let widthPercent: Double
    private let heightPercent: Double

    init(position: QuakeTerminalPosition, on screen: NSScreen, widthPercent: Double, heightPercent: Double) {
        self.position = position
        self.screen = screen
        self.widthPercent = widthPercent
        self.heightPercent = heightPercent
    }

    func setInitial(in window: NSWindow) {
        window.alphaValue = 0
        let size = configuredFrameSize()
        window.setFrame(.init(
            origin: position.initialOrigin(visibleFrame: screen.visibleFrame, windowSize: size),
            size: size
        ), display: false)
    }

    func setFinal(in window: NSWindow) {
        window.alphaValue = 1
        let size = configuredFrameSize()
        window.setFrame(.init(
            origin: position.finalOrigin(visibleFrame: screen.visibleFrame, windowSize: size),
            size: size
        ), display: true)
    }

    static func targetScreen(
        settings: SettingsStore,
        screens: [NSScreen],
        mainScreen: NSScreen?,
        monitors: () -> [Monitor],
        focusedWindowScreenProvider: @MainActor () -> NSScreen?
    ) -> NSScreen {
        switch settings.quakeTerminal.monitorMode {
        case .mouseCursor:
            let mouseLocation = NSEvent.mouseLocation
            if let monitor = mouseLocation.monitorApproximation(in: monitors()),
               let screen = screens.first(where: { $0.displayId == monitor.displayId })
            {
                return screen
            }

        case .focusedWindow:
            if let screen = focusedWindowScreenProvider() {
                return screen
            }
            if let screen = QuakeFocusedWindowScreen.find(monitors: monitors(), screens: screens) {
                return screen
            }

        case .mainMonitor:
            if !settings.monitors.ranking.isEmpty,
               let monitor = MonitorRanking.roleOrder(
                   ranking: settings.monitors.ranking,
                   sortedMonitors: Monitor.sortedByPosition(monitors())
               ).first,
               let screen = screens.first(where: { $0.frame == monitor.frame })
               ?? screens.first(where: { $0.displayId == monitor.displayId })
            {
                return screen
            }
            return screens.first ?? mainScreen!
        }

        return mainScreen ?? screens.first!
    }

    private func configuredFrameSize() -> NSSize {
        QuakeTerminalGeometryPolicy.configuredFrameSize(
            visibleFrame: screen.visibleFrame,
            widthPercent: widthPercent,
            heightPercent: heightPercent
        )
    }
}
