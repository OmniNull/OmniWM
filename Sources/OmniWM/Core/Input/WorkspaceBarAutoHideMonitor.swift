// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class WorkspaceBarAutoHideMonitor {
    var targets: () -> [WorkspaceBarAutoHideTarget] = { [] }
    var pointer: () -> CGPoint = { NSEvent.mouseLocation }
    var onRevealChanged: () -> Void = {}
    private(set) var state = WorkspaceBarAutoHideState()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    func start() {
        if !isRunning {
            isRunning = true
            let mask: NSEvent.EventTypeMask = [
                .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp
            ]
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.refresh()
                return event
            }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            for name in [
                NSApplication.didUpdateNotification,
                NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
                NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                NSWindow.didChangeOcclusionStateNotification
            ] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                })
            }
        }
        refresh()
    }

    func refresh() {
        guard isRunning else { return }
        let previous = state.revealed
        state.update(targets: targets(), pointer: pointer())
        if previous != state.revealed { onRevealChanged() }
    }

    func stop() {
        isRunning = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        let hadReveal = !state.revealed.isEmpty
        state.reset()
        if hadReveal { onRevealChanged() }
    }
}
