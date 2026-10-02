// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class WindowSwitcherPanel: NSPanel {
    struct Content {
        let items: [WindowSwitcherItem]
        let selected: WindowToken?
        let scope: WindowSwitcherScope
        let hasCaptureAccess: Bool
    }

    private static let surfaceId = "window-switcher"
    private let ownedWindowRegistry: OwnedWindowRegistry
    private let effectView = NSVisualEffectView()
    private var tiles: [WindowSwitcherTile] = []
    var onSelect: (WindowToken) -> Void = { _ in }
    var onToggleScope: () -> Void = {}

    init(ownedWindowRegistry: OwnedWindowRegistry) {
        self.ownedWindowRegistry = ownedWindowRegistry
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 22
        effectView.layer?.masksToBounds = true
        contentView = effectView
        setAccessibilityLabel(String(localized: "Window Switcher"))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(
        content: Content,
        screenFrame: CGRect,
        cachedPreview: (WindowHandle) -> OverviewPreviewFrame?
    ) -> [WindowSwitcherItem] {
        let maximumWidth = max(240, screenFrame.width - 64)
        let tileWidth = min(220, maximumWidth - 32)
        let capacity = max(1, Int((maximumWidth - 20) / (tileWidth + 12)))
        let selectedIndex = content.selected.flatMap { token in content.items.firstIndex { $0.handle.id == token } } ?? 0
        let start = min(max(0, selectedIndex - capacity / 2), max(0, content.items.count - capacity))
        let displayed = Array(content.items.dropFirst(start).prefix(capacity))
        let width = max(min(360, maximumWidth), 20 + CGFloat(displayed.count) * (tileWidth + 12))
        let height = min(266, screenFrame.height - 48)
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effectView.material = reduceTransparency ? .windowBackground : .hudWindow
        effectView.blendingMode = reduceTransparency ? .withinWindow : .behindWindow
        effectView.subviews.forEach { $0.removeFromSuperview() }
        layoutTiles(
            displayed,
            content: content,
            size: CGSize(width: tileWidth, height: max(80, height - 60)),
            cachedPreview: cachedPreview
        )
        layoutFooter(content: content, selectedIndex: selectedIndex, width: width)
        setFrame(
            CGRect(x: screenFrame.midX - width / 2, y: screenFrame.midY - height / 2, width: width, height: height),
            display: true
        )
        ownedWindowRegistry.register(
            self,
            surfaceId: Self.surfaceId,
            policy: SurfacePolicy(
                kind: .utility,
                hitTestPolicy: .interactive,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: true
            )
        )
        orderFrontRegardless()
        return displayed
    }

    private func layoutTiles(
        _ items: [WindowSwitcherItem],
        content: Content,
        size: CGSize,
        cachedPreview: (WindowHandle) -> OverviewPreviewFrame?
    ) {
        tiles = items.enumerated().map { index, item in
            let tile = WindowSwitcherTile(
                item: item,
                size: size,
                selected: item.handle.id == content.selected,
                hasCaptureAccess: content.hasCaptureAccess
            )
            tile.frame.origin = CGPoint(x: 16 + CGFloat(index) * (size.width + 12), y: 44)
            tile.onSelect = { [weak self] in self?.onSelect(item.handle.id) }
            tile.updatePreview(cachedPreview(item.handle))
            effectView.addSubview(tile)
            return tile
        }
    }

    private func layoutFooter(content: Content, selectedIndex: Int, width: CGFloat) {
        let scopeButton = NSButton(
            title: content.scope == .allWorkspaces
                ? String(localized: "All Workspaces") : String(localized: "Active Workspace"),
            target: self,
            action: #selector(toggleScope)
        )
        scopeButton.bezelStyle = .rounded
        scopeButton.frame = CGRect(x: 16, y: 10, width: 170, height: 26)
        scopeButton.toolTip = String(localized: "Press W to toggle workspace scope")
        effectView.addSubview(scopeButton)
        let count = NSTextField(labelWithString: content.items.isEmpty
            ? String(localized: "No windows in this workspace")
            : String(localized: "\(selectedIndex + 1) of \(content.items.count)"))
        count.alignment = .right
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        count.frame = CGRect(x: 192, y: 15, width: width - 208, height: 16)
        effectView.addSubview(count)
    }

    func updatePreview(_ frame: OverviewPreviewFrame?, for handle: WindowHandle) {
        tiles.first { $0.handle === handle }?.updatePreview(frame)
    }

    func setCapturePending(_ pending: Bool) {
        tiles.forEach { $0.setCapturePending(pending) }
    }

    func hide() {
        orderOut(nil)
        ownedWindowRegistry.unregister(surfaceId: Self.surfaceId)
        tiles.forEach { $0.updatePreview(nil) }
        tiles.removeAll()
        effectView.subviews.forEach { $0.removeFromSuperview() }
    }

    @objc private func toggleScope() {
        onToggleScope()
    }
}

@MainActor
private final class WindowSwitcherTile: NSView {
    let handle: WindowHandle
    private let thumbnail = CALayer()
    private let thumbnailBounds: CGRect
    private let unavailable = NSTextField(wrappingLabelWithString: "")
    private let hasCaptureAccess: Bool
    private var preview: OverviewPreviewFrame?
    var onSelect: () -> Void = {}

    init(item: WindowSwitcherItem, size: CGSize, selected: Bool, hasCaptureAccess: Bool) {
        handle = item.handle
        self.hasCaptureAccess = hasCaptureAccess
        thumbnailBounds = CGRect(x: 8, y: 28, width: size.width - 16, height: size.height - 60)
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = selected ? 3 : 1
        layer?.borderColor = (selected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.black.withAlphaComponent(selected ? 0.2 : 0.1).cgColor
        thumbnail.contentsGravity = .resize
        thumbnail.cornerRadius = 6
        thumbnail.masksToBounds = true
        layer?.addSublayer(thumbnail)

        let icon = NSImageView(frame: CGRect(x: 10, y: size.height - 27, width: 18, height: 18))
        icon.image = item.icon
        addSubview(icon)
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.frame = CGRect(x: 34, y: size.height - 26, width: size.width - 44, height: 18)
        addSubview(title)
        let subtitle = NSTextField(labelWithString: "\(item.appName) · \(item.workspaceName)")
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = CGRect(x: 10, y: 8, width: size.width - 20, height: 14)
        addSubview(subtitle)
        unavailable.alignment = .center
        unavailable.textColor = .secondaryLabelColor
        unavailable.font = .systemFont(ofSize: 11)
        unavailable.frame = CGRect(x: 16, y: thumbnailBounds.midY - 24, width: size.width - 32, height: 48)
        addSubview(unavailable)
        setCapturePending(true)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(item.appName), \(item.title), \(item.workspaceName)")
        setAccessibilityValue(selected ? String(localized: "Selected") : "")
        toolTip = item.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setCapturePending(_ pending: Bool) {
        unavailable.stringValue = !hasCaptureAccess
            ? String(localized: "Screen Recording permission required")
            : (pending ? String(localized: "Loading preview…") : String(localized: "Preview unavailable"))
    }

    func updatePreview(_ frame: OverviewPreviewFrame?) {
        let previous = preview
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { withExtendedLifetime(previous) {} }
        preview = frame
        thumbnail.contents = frame?.surface
        thumbnail.contentsRect = frame?.contentsRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let size = frame.map {
            CGSize(
                width: CGFloat($0.surface.width) * $0.contentsRect.width,
                height: CGFloat($0.surface.height) * $0.contentsRect.height
            )
        } ?? .zero
        thumbnail.frame = OverviewRenderGeometry.aspectFitRect(contentSize: size, in: thumbnailBounds)
        unavailable.isHidden = frame != nil
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onSelect()
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect()
        return true
    }
}
