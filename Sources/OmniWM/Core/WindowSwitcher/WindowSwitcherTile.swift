// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class WindowSwitcherTile: NSView {
    let handle: WindowHandle
    private let item: WindowSwitcherItem
    private let scope: WindowSwitcherScope
    private let thumbnail = CALayer()
    private let captionShade = CAGradientLayer()
    private let thumbnailBounds: CGRect
    private let unavailable = NSTextField(wrappingLabelWithString: "")
    private let hasCaptureAccess: Bool
    private let closeButton = NSButton()
    private var hoverTracking: NSTrackingArea?
    private var preview: OverviewPreviewFrame?
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}

    init(
        item: WindowSwitcherItem,
        size: CGSize,
        selected: Bool,
        content: WindowSwitcherPanel.Content
    ) {
        handle = item.handle
        self.item = item
        scope = content.scope
        hasCaptureAccess = content.hasCaptureAccess
        thumbnailBounds = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        setSelected(selected)
        configurePreviewLayer()
        layoutCaption(size: size)
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: String(localized: "Close Window")
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = .systemRed
        closeButton.frame = CGRect(x: 6, y: size.height - 28, width: 24, height: 24)
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.toolTip = String(localized: "Close Window")
        closeButton.isHidden = true
        addSubview(closeButton)
        unavailable.alignment = .center
        unavailable.textColor = .secondaryLabelColor
        unavailable.font = .systemFont(ofSize: 11)
        unavailable.frame = CGRect(x: 16, y: thumbnailBounds.midY - 24, width: size.width - 32, height: 48)
        addSubview(unavailable)
        setCapturePending(true)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(item.appName), \(item.title), \(item.workspaceName)")
        toolTip = item.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func matches(_ item: WindowSwitcherItem, size: CGSize, content: WindowSwitcherPanel.Content) -> Bool {
        handle === item.handle && self.item.title == item.title && self.item.appName == item.appName
            && self.item.workspaceName == item.workspaceName && self.item.icon === item.icon
            && bounds.size == size && scope == content.scope
            && hasCaptureAccess == content.hasCaptureAccess
    }

    func setSelected(_ selected: Bool) {
        layer?.borderWidth = selected ? 3 : 1
        layer?.borderColor = (selected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.black.withAlphaComponent(selected ? 0.2 : 0.1).cgColor
        setAccessibilityValue(selected ? String(localized: "Selected") : "")
    }

    private func layoutCaption(size: CGSize) {
        let icon = NSImageView(frame: CGRect(x: 8, y: 6, width: 16, height: 16))
        icon.image = item.icon
        addSubview(icon)
        let badgeWidth = scope == .allWorkspaces ? layoutWorkspaceBadge(item.workspaceName, size: size) : 0
        let title = NSTextField(labelWithString: WindowSwitcherTitle.label(appName: item.appName, title: item.title))
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .white
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        title.shadow = shadow
        title.lineBreakMode = .byTruncatingTail
        title.frame = CGRect(x: 28, y: 5, width: size.width - 38 - badgeWidth, height: 18)
        addSubview(title)
    }

    private func configurePreviewLayer() {
        thumbnail.contentsGravity = .resizeAspectFill
        thumbnail.cornerRadius = 6
        thumbnail.masksToBounds = true
        layer?.addSublayer(thumbnail)
        captionShade.frame = CGRect(x: 2, y: 2, width: bounds.width - 4, height: 36)
        let stops = (0 ... 8).map { CGFloat($0) / 8 }
        captionShade.colors = stops.map { position in
            let progress = position * position * (3 - 2 * position)
            return CGColor(gray: 0, alpha: 0.5 * (1 - progress))
        }
        captionShade.locations = stops.map { NSNumber(value: Double($0)) }
        captionShade.startPoint = CGPoint(x: 0.5, y: 0)
        captionShade.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.addSublayer(captionShade)
    }

    private func layoutWorkspaceBadge(_ name: String, size: CGSize) -> CGFloat {
        let label = NSTextField(labelWithString: name)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.sizeToFit()
        let width = min(max(26, label.frame.width + 16), (size.width - 20) / 2)
        let badge = NSView(frame: CGRect(x: size.width - 10 - width, y: 5, width: width, height: 20))
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.layer?.backgroundColor = NSColor(white: 0.19, alpha: 0.9).cgColor
        label.frame = CGRect(x: 8, y: 3, width: width - 16, height: 14)
        badge.addSubview(label)
        badge.toolTip = name
        addSubview(badge)
        return width + 8
    }

    func setCapturePending(_ pending: Bool) {
        unavailable.stringValue = !hasCaptureAccess
            ? String(localized: "Screen Recording permission required")
            : (pending ? String(localized: "Loading preview…") : String(localized: "Preview unavailable"))
    }

    func updatePreview(_ frame: OverviewPreviewFrame?) {
        guard preview !== frame else { return }
        let previous = preview
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { withExtendedLifetime(previous) {} }
        preview = frame
        thumbnail.contents = frame?.surface
        thumbnail.contentsRect = frame?.contentsRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        thumbnail.frame = thumbnailBounds
        unavailable.isHidden = frame != nil
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if !closeButton.isHidden, closeButton.frame.contains(local) { return closeButton }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        hoverTracking = tracking
        if let window {
            closeButton.isHidden = !visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
    }

    @objc private func closeWindow() {
        onClose()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onSelect()
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect()
        return true
    }
}
