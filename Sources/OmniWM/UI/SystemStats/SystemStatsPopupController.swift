// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import SwiftUI

@MainActor
final class SystemStatsPopupPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

@MainActor
final class SystemStatsPopupController {
    private static let surfaceId = "system-stats-popup"

    var isToggleSourceWindow: (@MainActor (NSWindow) -> Bool)?

    private(set) var isVisible = false
    private var panel: SystemStatsPopupPanel?
    private let model = SystemStatsModel()
    private var refreshTask: Task<Void, Never>?
    private var eventMonitors: [Any] = []
    private var anchoredMonitorId: Monitor.ID?

    func toggle(anchor: CGPoint, monitorId: Monitor.ID, screenVisibleFrame: CGRect) {
        if isVisible {
            dismiss()
        } else {
            show(anchor: anchor, monitorId: monitorId, screenVisibleFrame: screenVisibleFrame)
        }
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        anchoredMonitorId = nil
        refreshTask?.cancel()
        refreshTask = nil
        removeEventMonitors()
        OwnedWindowRegistry.shared.unregister(surfaceId: Self.surfaceId)
        panel?.orderOut(nil)
    }

    func dismissIfAnchored(to monitorId: Monitor.ID) {
        if anchoredMonitorId == monitorId {
            dismiss()
        }
    }

    nonisolated static func popupFrame(anchor: CGPoint, size: CGSize, screenVisibleFrame: CGRect) -> CGRect {
        var frame = CGRect(
            x: anchor.x - size.width / 2,
            y: anchor.y - 4 - size.height,
            width: size.width,
            height: size.height
        )
        let minX = screenVisibleFrame.minX + 8
        let maxX = screenVisibleFrame.maxX - size.width - 8
        frame.origin.x = maxX >= minX ? min(max(frame.origin.x, minX), maxX) : minX
        frame.origin.y = min(
            max(frame.origin.y, screenVisibleFrame.minY + 8),
            screenVisibleFrame.maxY - size.height
        )
        return frame
    }

    static func targetMonitor(
        pointer: Monitor?,
        main: Monitor?,
        monitors: [Monitor],
        hasAnchor: (Monitor.ID) -> Bool
    ) -> Monitor? {
        ([pointer, main].compactMap { $0 } + monitors).first { hasAnchor($0.id) }
    }

    private func show(anchor: CGPoint, monitorId: Monitor.ID, screenVisibleFrame: CGRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        anchoredMonitorId = monitorId
        model.snapshot = nil
        panel.setFrame(
            Self.popupFrame(
                anchor: anchor,
                size: SystemStatsView.preferredSize,
                screenVisibleFrame: screenVisibleFrame
            ),
            display: true
        )
        OwnedWindowRegistry.shared.register(
            panel,
            surfaceId: Self.surfaceId,
            policy: SurfacePolicy(
                kind: .systemStats,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        panel.orderFrontRegardless()
        isVisible = true
        startRefresh(displayResolutions: Self.displayResolutions())
        installEventMonitors(panel: panel)
    }

    private func makePanel() -> SystemStatsPopupPanel {
        let panel = SystemStatsPopupPanel(
            contentRect: CGRect(origin: .zero, size: SystemStatsView.preferredSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: SystemStatsView(model: model))
        return panel
    }

    private func startRefresh(displayResolutions: [String]) {
        refreshTask?.cancel()
        let stream = SystemStatsRefreshStream.stream(displayResolutions: displayResolutions)
        refreshTask = Task { @MainActor [weak self] in
            for await snapshot in stream {
                guard let self, !Task.isCancelled, isVisible else { return }
                model.snapshot = snapshot
            }
        }
    }

    private static func displayResolutions() -> [String] {
        NSScreen.screens.map { screen in
            let scale = screen.backingScaleFactor
            let width = Int(screen.frame.width * scale)
            let height = Int(screen.frame.height * scale)
            return String(localized: "\(width)×\(height) @ \(screen.maximumFramesPerSecond) Hz")
        }
    }

    private func installEventMonitors(panel: SystemStatsPopupPanel) {
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            self?.handleLocalEvent(event)
            return event
        }
        let globalMouse = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismissIfPointerOutsidePanel()
            }
        }
        let globalKey = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                if event.keyCode == 53 {
                    self?.dismiss()
                }
            }
        }
        eventMonitors = [local, globalMouse, globalKey].compactMap { $0 }
    }

    private func removeEventMonitors() {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors = []
    }

    private func handleLocalEvent(_ event: NSEvent) {
        guard isVisible else { return }
        if event.type == .keyDown {
            if event.keyCode == 53 {
                dismiss()
            }
            return
        }
        guard let window = event.window else {
            dismissIfPointerOutsidePanel()
            return
        }
        if window === panel {
            return
        }
        if isToggleSourceWindow?(window) == true {
            return
        }
        dismiss()
    }

    private func dismissIfPointerOutsidePanel() {
        guard let panel, isVisible else { return }
        if !panel.frame.contains(NSEvent.mouseLocation) {
            dismiss()
        }
    }
}
