// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

extension ShellWidgetHost {
    func connectIslandInput(_ island: ShellIsland, on monitor: Monitor.ID) {
        island.onFocusChange = { [weak self, weak island] focused in
            guard let self, let island, islandWindows[monitor] === island else { return }
            if focused { focusShellSurface(island.surface) }
            else if !retainsPickerFocus(on: island.surface) {
                releaseShellFocus(from: island.surface, restore: !island.panel.isResigningKey)
            }
        }
        island.onBlur = { [weak self, weak island] in
            guard let self, let island, islandWindows[monitor] === island else { return }
            shellWindowResigned(from: island.surface)
        }
        island.onInputChange = { [weak self] in
            self?.updateIslandInputMonitoring()
            self?.updateIslandDragMonitoring()
        }
        island.surface.onResourceDragEnd = { [weak self, weak island] in
            guard let self, let island, islandWindows[monitor] === island else { return }
            islandDragMonitor?.end()
        }
    }

    func releaseIslandFocus(on monitor: Monitor.ID, restore: Bool) {
        guard let island = islandWindows[monitor] else { return }
        releaseShellFocus(from: island.surface, restore: restore)
    }

    func publishIslandFocus() {
        var changed = false
        for key in islandData.keys {
            let focused = focusedIsland == key.monitor
            if islandData[key]?.surface?.focused != focused {
                islandData[key]?.surface?.focused = focused
                changed = true
            }
        }
        if changed, let root = config.island?.root, let state = widgets[root] {
            state.mailbox?.yield(.bars(bars(for: state)))
        }
    }

    func updateIslandInputMonitoring() {
        let demanded = focusedSurface != nil || islandWindows.values.contains {
            $0.panel.isVisible && $0.hasOutsidePress
        }
        guard demanded else {
            stopIslandInputMonitoring()
            return
        }
        guard islandInputMonitors == nil else { return }
        islandInputGeneration += 1
        let generation = islandInputGeneration
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleIslandLocalPress(event, generation: generation) ?? event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let quartzPoint = event.cgEvent?.location
            let point = event.locationInWindow
            let input = Self.islandPressEvent(event)
            DispatchQueue.main.async { [weak self] in
                self?.handleIslandOutsidePress(
                    at: quartzPoint.map { ScreenCoordinateSpace.toAppKit(point: $0) } ?? point,
                    event: input,
                    generation: generation
                )
            }
        }
        islandInputMonitors = [local, global].compactMap { $0 }
        if islandInputMonitors?.count != 2 {
            Log.shell.error("Could not install all shell island outside-press monitors")
        }
    }

    func stopIslandInputMonitoring() {
        guard let monitors = islandInputMonitors else { return }
        islandInputGeneration += 1
        islandInputMonitors = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
    }

    func handleIslandLocalPress(_ event: NSEvent, generation: Int) -> NSEvent {
        let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        handleIslandOutsidePress(at: point, event: Self.islandPressEvent(event), generation: generation)
        return event
    }

    func handleIslandOutsidePress(at point: CGPoint, event: ShellEvent, generation: Int) {
        guard islandInputMonitors != nil, islandInputGeneration == generation else { return }
        if let source = focusedSurface, !isPresentingPicker(on: source),
           !containsShellFocus(source, at: point), !acceptsShellFocus(at: point)
        {
            releaseShellFocus(from: source, restore: false)
        }
        for island in islandWindows.values where !isPresentingPicker(on: island.surface) {
            island.outsidePress(at: point, event: event)
        }
    }

    private nonisolated static func islandPressEvent(_ event: NSEvent) -> ShellEvent {
        let button: ShellEvent.Button = switch event.type {
        case .rightMouseDown: .right
        case .otherMouseDown: .middle
        default: .left
        }
        var input = ShellEvent(button: button, modifiers: event.modifierFlags)
        input.kind = .outsidePress
        input.clicks = event.clickCount
        return input
    }
}
