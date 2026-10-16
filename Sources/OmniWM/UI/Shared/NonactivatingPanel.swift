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
    private var containsPanelPoint: ((NSPanel, CGPoint) -> Bool)?
    private var onEscape: (() -> Void)?
    private var shouldHandleEscape: (() -> Bool)?
    private var shouldDismissOnScreenChange: (() -> Bool)?
    private var onDismiss: (() -> Void)?
    private var eventMonitors: [Any] = []
    private var screenObserver: NSObjectProtocol?

    func start(
        panels: [NSPanel],
        isExemptWindow: @escaping (NSWindow) -> Bool,
        containsPanelPoint: ((NSPanel, CGPoint) -> Bool)? = nil,
        onEscape: (() -> Void)? = nil,
        shouldHandleEscape: (() -> Bool)? = nil,
        shouldDismissOnScreenChange: (() -> Bool)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        stop()
        self.panels = panels
        self.isExemptWindow = isExemptWindow
        self.containsPanelPoint = containsPanelPoint
        self.onEscape = onEscape
        self.shouldHandleEscape = shouldHandleEscape
        self.shouldDismissOnScreenChange = shouldDismissOnScreenChange
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
                guard self?.shouldDismissOnScreenChange?() != false else { return }
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
        containsPanelPoint = nil
        onEscape = nil
        shouldHandleEscape = nil
        shouldDismissOnScreenChange = nil
        onDismiss = nil
    }

    func handleLocalEvent(_ event: NSEvent) -> Bool {
        guard !hasOwnedChildPresentation, !panels.isEmpty else { return false }
        if event.type == .keyDown {
            if event.keyCode == 53 {
                return handleEscape()
            }
            return false
        }
        guard let window = event.window else {
            handlePointer(location: NSEvent.mouseLocation)
            return false
        }
        if let panel = panels.first(where: { $0 === window }) {
            if containsPointer(window.convertPoint(toScreen: event.locationInWindow), in: panel) {
                return false
            }
            onDismiss?()
            return true
        }
        if isExemptWindow?(window) == true {
            return false
        }
        onDismiss?()
        return false
    }

    func handlePointer(location: CGPoint) {
        guard !hasOwnedChildPresentation, !panels.isEmpty else { return }
        if !panels.contains(where: { containsPointer(location, in: $0) }) {
            onDismiss?()
        }
    }

    private var hasOwnedChildPresentation: Bool {
        panels.contains { ($0 as? ShellFocusPanel)?.hasOwnedChildPresentation?() == true }
    }

    private func containsPointer(_ location: CGPoint, in panel: NSPanel) -> Bool {
        panel.frame.contains(location) && (containsPanelPoint?(panel, location) ?? true)
    }

    @discardableResult
    private func handleEscape() -> Bool {
        guard !hasOwnedChildPresentation, !panels.isEmpty, shouldHandleEscape?() != false else { return false }
        (onEscape ?? onDismiss)?()
        return true
    }
}
