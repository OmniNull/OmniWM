// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

struct HiddenBarFallbackIconPlacement: Equatable {
    let monitorId: Monitor.ID
    let frame: CGRect
}

@MainActor
final class HiddenBarFallbackIconButton: NSButton {
    var onClick: ((NSEvent, NSView) -> Void)?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func rightMouseDown(with _: NSEvent) {}

    override func rightMouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            onClick?(event, self)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let event = activationEvent() else { return false }
        onClick?(event, self)
        return onClick != nil
    }

    @objc func activate(_: NSButton) {
        guard let event = NSApp.currentEvent ?? activationEvent() else { return }
        onClick?(event, self)
    }

    private func activationEvent() -> NSEvent? {
        NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: CGPoint(x: bounds.midX, y: bounds.midY),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )
    }
}

@MainActor
final class HiddenBarFallbackIconController {
    private static let accessibilityHelp = String(
        localized: "Press to open the OmniWM menu. Right-click or Option-click to show hidden icons when Hidden Bar is enabled."
    )

    nonisolated static let gap: CGFloat = 8
    nonisolated static let fallbackSide: CGFloat = 24

    var onClick: ((NSEvent, NSView) -> Void)?

    private var panelsByMonitor: [Monitor.ID: WorkspaceBarPanel] = [:]

    nonisolated static func iconFrame(
        monitor: Monitor,
        barVisible: Bool,
        barFrame: CGRect?,
        position: WorkspaceBarPosition = .overlappingMenuBar
    ) -> CGRect {
        if barVisible, let barFrame {
            if position.isVertical {
                let side = barFrame.width
                if barFrame.minY - gap - side >= monitor.visibleFrame.minY {
                    return CGRect(x: barFrame.minX, y: barFrame.minY - gap - side, width: side, height: side)
                }
                if barFrame.maxY + gap + side <= monitor.visibleFrame.maxY {
                    return CGRect(x: barFrame.minX, y: barFrame.maxY + gap, width: side, height: side)
                }
                let x = position == .left ? barFrame.maxX + gap : barFrame.minX - gap - side
                return CGRect(x: x, y: monitor.visibleFrame.minY, width: side, height: side)
            }
            let side = barFrame.height
            let x = max(barFrame.minX - gap - side, monitor.frame.minX + 8)
            return CGRect(x: x, y: barFrame.minY, width: side, height: side)
        }
        return CGRect(
            x: monitor.frame.midX - fallbackSide / 2,
            y: monitor.visibleFrame.maxY - 4 - fallbackSide,
            width: fallbackSide,
            height: fallbackSide
        )
    }

    func show(placements: [HiddenBarFallbackIconPlacement]) {
        var stale = Set(panelsByMonitor.keys)
        for placement in placements {
            stale.remove(placement.monitorId)
            let panel = panelsByMonitor[placement.monitorId] ?? makePanel(monitorId: placement.monitorId)
            if panel.frame != placement.frame {
                panel.setFrame(placement.frame, display: true)
            }
            panel.orderFrontRegardless()
        }
        for monitorId in stale {
            removePanel(monitorId: monitorId)
        }
    }

    func dismiss() {
        for monitorId in Array(panelsByMonitor.keys) {
            removePanel(monitorId: monitorId)
        }
    }

    func owns(window: NSWindow) -> Bool {
        panelsByMonitor.values.contains { $0 === window }
    }

    private func makePanel(monitorId: Monitor.ID) -> WorkspaceBarPanel {
        let panel = WorkspaceBarPanel.defaultPanel()
        panel.level = .statusBar

        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.masksToBounds = true
        let button = HiddenBarFallbackIconButton(
            image: OmniWMBrandMark.statusItemImage(pointSize: 14),
            target: nil,
            action: nil
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = button
        button.action = #selector(HiddenBarFallbackIconButton.activate(_:))
        button.onClick = { [weak self] event, anchor in
            self?.onClick?(event, anchor)
        }
        button.toolTip = "OmniWM"
        button.setAccessibilityElement(true)
        button.setAccessibilityLabel("OmniWM")
        button.setAccessibilityValue(String(localized: "Window manager controls"))
        button.setAccessibilityHelp(Self.accessibilityHelp)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            button.topAnchor.constraint(equalTo: view.topAnchor),
            button.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        panel.contentView = view
        OwnedWindowRegistry.shared.register(
            panel,
            surfaceId: Self.surfaceId(monitorId: monitorId),
            policy: SurfacePolicy(
                kind: .hiddenBarPanel,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        panelsByMonitor[monitorId] = panel
        return panel
    }

    private func removePanel(monitorId: Monitor.ID) {
        guard let panel = panelsByMonitor.removeValue(forKey: monitorId) else { return }
        OwnedWindowRegistry.shared.unregister(surfaceId: Self.surfaceId(monitorId: monitorId))
        panel.orderOut(nil)
        panel.close()
    }

    private nonisolated static func surfaceId(monitorId: Monitor.ID) -> String {
        "hidden-bar-fallback-\(monitorId)"
    }
}
