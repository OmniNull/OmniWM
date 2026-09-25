// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
final class WorkspaceBarPreviewPanel: NSPanel {
    private static let surfaceId = "workspace-bar-hover-preview"
    private static let padding: CGFloat = 8
    private static let textHeight: CGFloat = 34

    private let ownedWindowRegistry: OwnedWindowRegistry
    private let effectView = NSVisualEffectView()
    private var tiles: [WorkspaceBarPreviewTile] = []
    private var trackingArea: NSTrackingArea?
    var onSelect: (WindowHandle) -> Void = { _ in }
    var onPointerInside: (Bool) -> Void = { _ in }

    init(ownedWindowRegistry: OwnedWindowRegistry) {
        self.ownedWindowRegistry = ownedWindowRegistry
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 10
        effectView.layer?.masksToBounds = true
        contentView = effectView
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    static func tileSize(forWindowCount count: Int) -> CGSize {
        count > 1 ? CGSize(width: 160, height: 100) : CGSize(width: 240, height: 150)
    }

    func show(
        _ target: WorkspaceBarHoverTarget,
        windows: [WorkspaceBarHoverTarget.Window],
        overflowCount: Int,
        showsThumbnails: Bool,
        cachedPreview: (WindowHandle) -> OverviewPreviewFrame?
    ) {
        refreshAppearance()
        let size = layoutTiles(
            windows,
            overflowCount: overflowCount,
            showsThumbnails: showsThumbnails,
            cachedPreview: cachedPreview
        )
        level = NSWindow.Level(rawValue: target.level.rawValue + 1)
        ignoresMouseEvents = windows.count <= 1
        setFrame(
            NonactivatingPanel.frame(
                anchor: CGPoint(x: target.anchor.midX, y: target.anchor.minY - 2),
                size: size,
                screenVisibleFrame: target.visibleFrame
            ),
            display: true
        )
        updateTrackingArea()
        ownedWindowRegistry.register(
            self,
            surfaceId: Self.surfaceId,
            policy: SurfacePolicy(
                kind: .workspaceBar,
                hitTestPolicy: windows.count > 1 ? .interactive : .passthrough,
                capturePolicy: .excluded,
                suppressesManagedFocusRecovery: false
            )
        )
        orderFrontRegardless()
    }

    private func layoutTiles(
        _ windows: [WorkspaceBarHoverTarget.Window],
        overflowCount: Int,
        showsThumbnails: Bool,
        cachedPreview: (WindowHandle) -> OverviewPreviewFrame?
    ) -> CGSize {
        effectView.subviews.forEach { $0.removeFromSuperview() }
        let thumbnailSize = showsThumbnails ? Self.tileSize(forWindowCount: windows.count) : CGSize(
            width: 200,
            height: 0
        )
        let tileSize = CGSize(width: thumbnailSize.width, height: thumbnailSize.height + Self.textHeight)
        tiles = windows.enumerated().map { index, window in
            let tile = WorkspaceBarPreviewTile(
                window: window,
                thumbnailSize: thumbnailSize,
                isSelectable: windows.count > 1
            )
            tile.frame = CGRect(
                origin: CGPoint(x: Self.padding + CGFloat(index) * (tileSize.width + Self.padding), y: Self.padding),
                size: tileSize
            )
            tile.onSelect = { [weak self] in self?.onSelect(window.handle) }
            tile.updatePreview(cachedPreview(window.handle))
            effectView.addSubview(tile)
            return tile
        }
        var width = Self.padding + CGFloat(windows.count) * (tileSize.width + Self.padding)
        if overflowCount > 0 {
            let more = NSTextField(labelWithString: String(localized: "+\(overflowCount) more"))
            more.font = .systemFont(ofSize: 11, weight: .medium)
            more.textColor = .secondaryLabelColor
            more.sizeToFit()
            more.frame.origin = CGPoint(x: width, y: Self.padding + (tileSize.height - more.frame.height) / 2)
            effectView.addSubview(more)
            width += more.frame.width + Self.padding
        }
        return CGSize(width: width, height: tileSize.height + Self.padding * 2)
    }

    func updatePreview(_ frame: OverviewPreviewFrame?, for handle: WindowHandle) {
        tiles.first { $0.handle === handle }?.updatePreview(frame)
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
        ownedWindowRegistry.unregister(surfaceId: Self.surfaceId)
        tiles.forEach { $0.updatePreview(nil) }
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerInside(true)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerInside(false)
    }

    private func updateTrackingArea() {
        if let trackingArea {
            effectView.removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: effectView.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        effectView.addTrackingArea(area)
        trackingArea = area
    }

    private func refreshAppearance() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effectView.material = reduceTransparency ? .windowBackground : .hudWindow
        effectView.blendingMode = reduceTransparency ? .withinWindow : .behindWindow
    }
}

@MainActor
private final class WorkspaceBarPreviewTile: NSView {
    let handle: WindowHandle
    private let thumbnail = CALayer()
    private let thumbnailBounds: CGRect
    private let iconView = NSImageView()
    private let isSelectable: Bool
    private var preview: OverviewPreviewFrame?
    var onSelect: () -> Void = {}

    init(window: WorkspaceBarHoverTarget.Window, thumbnailSize: CGSize, isSelectable: Bool) {
        handle = window.handle
        self.isSelectable = isSelectable
        thumbnailBounds = CGRect(x: 0, y: 34, width: thumbnailSize.width, height: thumbnailSize.height)
        super.init(frame: CGRect(x: 0, y: 0, width: thumbnailSize.width, height: thumbnailSize.height + 34))
        wantsLayer = true
        if thumbnailSize.height > 0 {
            let placeholder = CALayer()
            placeholder.frame = thumbnailBounds
            placeholder.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
            placeholder.cornerRadius = 6
            layer?.addSublayer(placeholder)
            iconView.image = window.icon
            iconView.frame = CGRect(x: thumbnailBounds.midX - 16, y: thumbnailBounds.midY - 16, width: 32, height: 32)
            addSubview(iconView)
            thumbnail.contentsGravity = .resize
            thumbnail.cornerRadius = 4
            thumbnail.masksToBounds = true
            layer?.addSublayer(thumbnail)
        }
        let title = label(window.title, size: 12, weight: .medium, color: .labelColor)
        title.frame = CGRect(x: 0, y: 16, width: thumbnailSize.width, height: 16)
        let app = label(window.appName, size: 10.5, weight: .regular, color: .secondaryLabelColor)
        app.frame = CGRect(x: 0, y: 1, width: thumbnailSize.width, height: 14)
        addSubview(title)
        addSubview(app)
        setAccessibilityElement(true)
        setAccessibilityRole(isSelectable ? .button : .group)
        setAccessibilityLabel(String(localized: "\(window.appName), \(window.title)"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
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
        let contentSize = frame.map {
            CGSize(
                width: CGFloat($0.surface.width) * $0.contentsRect.width,
                height: CGFloat($0.surface.height) * $0.contentsRect.height
            )
        } ?? .zero
        thumbnail.frame = OverviewRenderGeometry.aspectFitRect(contentSize: contentSize, in: thumbnailBounds)
        iconView.isHidden = frame != nil
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isSelectable else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        guard isSelectable, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onSelect()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        return field
    }
}
