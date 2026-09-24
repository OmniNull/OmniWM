// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

enum TabRailHoverCardPlacement {
    static func frame(
        railFrame: CGRect,
        itemRect: CGRect,
        cardSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat
    ) -> CGRect {
        let itemCenterY = railFrame.minY + itemRect.midY
        let leftX = railFrame.minX - gap - cardSize.width
        let rightX = railFrame.maxX + gap
        let x = leftX >= visibleFrame.minX ? leftX : min(rightX, visibleFrame.maxX - cardSize.width)
        let unclampedY = itemCenterY - cardSize.height / 2
        let y = min(
            max(unclampedY, visibleFrame.minY),
            max(visibleFrame.minY, visibleFrame.maxY - cardSize.height)
        )
        return CGRect(
            origin: CGPoint(x: max(visibleFrame.minX, x), y: y),
            size: cardSize
        )
    }
}

@MainActor
final class TabRailHoverCardWindow: NSPanel {
    private let effectView = NSVisualEffectView(frame: .zero)
    private let iconView = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: TabRailMetrics.hoverCardSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        ignoresMouseEvents = true
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 10
        effectView.layer?.masksToBounds = true
        contentView = effectView

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(iconView)
        effectView.addSubview(titleLabel)
        effectView.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 9),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2)
        ])
        refreshAppearance()
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func show(tab: TabRailTabInfo, tabCount: Int, frame: CGRect) {
        let app = tab.token.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
        iconView.image = app?.icon ?? NSImage(named: NSImage.applicationIconName)
        titleLabel.stringValue = tab.title?.nilIfEmpty
            ?? tab.appName?.nilIfEmpty
            ?? String(localized: "Untitled window")
        let appName = tab.appName?.nilIfEmpty ?? app?.localizedName?.nilIfEmpty ?? String(localized: "Window")
        detailLabel.stringValue = String(localized: "\(appName) · Tab \(tab.visualIndex + 1) of \(tabCount)")
        setFrame(frame, display: false)
        orderFront(nil)
    }

    func hide() {
        if isVisible {
            orderOut(nil)
        }
    }

    func refreshAppearance() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effectView.material = reduceTransparency ? .windowBackground : .hudWindow
        effectView.blendingMode = reduceTransparency ? .withinWindow : .behindWindow
        effectView.layer?.backgroundColor = reduceTransparency
            ? NSColor.windowBackgroundColor.cgColor
            : NSColor.clear.cgColor
        effectView.layer?.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.5
        effectView.layer?.borderColor = TabRailMetrics.trackBorderColor.cgColor
        titleLabel.textColor = .labelColor
        detailLabel.textColor = .secondaryLabelColor
    }
}
