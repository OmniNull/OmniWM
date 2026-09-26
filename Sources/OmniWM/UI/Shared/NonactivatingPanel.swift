// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class NonactivatingPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

@MainActor
final class PanelDismissalMonitor {
    private var panels: [NSPanel] = []
    private var isExemptWindow: ((NSWindow) -> Bool)?
    private var onEscape: (() -> Void)?
    private var onDismiss: (() -> Void)?
    private var eventMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?

    func start(
        panels: [NSPanel],
        isExemptWindow: @escaping (NSWindow) -> Bool,
        onEscape: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        stop()
        self.panels = panels
        self.isExemptWindow = isExemptWindow
        self.onEscape = onEscape
        self.onDismiss = onDismiss

        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            self?.handleLocalEvent(event) == true ? nil : event
        }
        let globalMouse = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePointer(location: NSEvent.mouseLocation)
            }
        }
        let globalKey = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                if event.keyCode == 53 {
                    self?.handleEscape()
                }
            }
        }
        eventMonitors = [local, globalMouse, globalKey].compactMap { $0 }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onDismiss?()
            }
        }
    }

    func updatePanels(_ panels: [NSPanel]) {
        self.panels = panels
    }

    func stop() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors = []
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        panels = []
        isExemptWindow = nil
        onEscape = nil
        onDismiss = nil
    }

    func handleLocalEvent(_ event: NSEvent) -> Bool {
        guard !panels.isEmpty else { return false }
        if event.type == .keyDown {
            if event.keyCode == 53 {
                handleEscape()
                return true
            }
            return false
        }
        guard let window = event.window else {
            handlePointer(location: NSEvent.mouseLocation)
            return false
        }
        if panels.contains(where: { $0 === window }) || isExemptWindow?(window) == true {
            return false
        }
        onDismiss?()
        return false
    }

    func handlePointer(location: CGPoint) {
        guard !panels.isEmpty else { return }
        if !panels.contains(where: { $0.frame.contains(location) }) {
            onDismiss?()
        }
    }

    private func handleEscape() {
        guard !panels.isEmpty else { return }
        (onEscape ?? onDismiss)?()
    }
}
