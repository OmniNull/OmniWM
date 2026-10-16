// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

@MainActor
final class ShellTooltip {
    private static let offset = CGPoint(x: 10, y: 22)
    private static let padding = CGSize(width: 8, height: 4)

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 4
        label.font = .toolTipsFont(ofSize: 0)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Self.padding.width),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
        panel.contentView = background
    }

    var text: String? {
        panel.isVisible ? label.stringValue : nil
    }

    func show(_ text: String, at location: CGPoint) {
        guard !text.isEmpty else {
            hide()
            return
        }
        label.stringValue = text
        let size = label.fittingSize
        let frameSize = CGSize(
            width: size.width + Self.padding.width * 2,
            height: size.height + Self.padding.height * 2
        )
        var origin = CGPoint(x: location.x + Self.offset.x, y: location.y - Self.offset.y - frameSize.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - frameSize.width)
            origin.y = max(origin.y, visible.minY)
        }
        panel.setFrame(CGRect(origin: origin, size: frameSize), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
