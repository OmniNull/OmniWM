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
        var showsFooter = true
    }

    private static let surfaceId = "window-switcher"
    private static let backgroundMask: NSImage = {
        let radius: CGFloat = 22
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }()

    private let ownedWindowRegistry: OwnedWindowRegistry
    private let effectView = NSVisualEffectView()
    private var tiles: [WindowSwitcherTile] = []
    private let scrollView = NSScrollView()
    private let gridView = WindowSwitcherGridView()
    private var items: [WindowSwitcherItem] = []
    private var selected: WindowToken?
    private var isLayingOut = false
    private(set) var columns = 1
    var onSelect: (WindowToken) -> Void = { _ in }
    var onClose: (WindowToken) -> Void = { _ in }
    var onVisibleItemsChanged: ([WindowSwitcherItem]) -> Void = { _ in }
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
        // Mask the material and window shadow as well as the visible background.
        effectView.maskImage = Self.backgroundMask
        contentView = effectView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = gridView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        setAccessibilityLabel(String(localized: "Window Switcher"))
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func show(
        content: Content,
        screenFrame: CGRect
    ) {
        isLayingOut = true
        let oldOrigin = scrollView.contentView.bounds.origin
        let revealSelection = !isVisible || selected != content.selected || items.map(\.handle.id) != content.items
            .map(\.handle.id)
        items = content.items
        selected = content.selected
        let maximumWidth = max(240, screenFrame.width - 64)
        let tileWidth = min(220, maximumWidth - 32)
        columns = max(1, min(content.items.count, Int((maximumWidth - 20) / (tileWidth + 12))))
        let selectedIndex = content.selected
            .flatMap { token in content.items.firstIndex { $0.handle.id == token } } ?? 0
        let width = max(min(360, maximumWidth), 20 + CGFloat(columns) * (tileWidth + 12))
        let footerHeight: CGFloat = content.showsFooter ? 28 : 0
        let tileHeight: CGFloat = 207
        let rows = max(1, (content.items.count + columns - 1) / columns)
        let documentHeight = CGFloat(rows) * (tileHeight + 12) - 12
        let viewportHeight = min(documentHeight, max(80, screenFrame.height - 80 - footerHeight))
        let height = viewportHeight + 32 + footerHeight
        updateMaterial()
        effectView.subviews.forEach { $0.removeFromSuperview() }
        scrollView.frame = CGRect(x: 16, y: 16 + footerHeight, width: width - 32, height: viewportHeight)
        gridView.frame = CGRect(x: 0, y: 0, width: width - 32, height: documentHeight)
        effectView.addSubview(scrollView)
        gridView.subviews.forEach { $0.removeFromSuperview() }
        layoutTiles(
            content.items,
            content: content,
            size: CGSize(width: tileWidth, height: tileHeight)
        )
        if content.showsFooter {
            layoutFooter(content: content, selectedIndex: selectedIndex, width: width)
        } else if content.items.isEmpty {
            layoutEmptyState(size: CGSize(width: width, height: height))
        }
        setFrame(
            CGRect(x: screenFrame.midX - width / 2, y: screenFrame.midY - height / 2, width: width, height: height),
            display: true
        )
        registerSurface()
        orderFrontRegardless()
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: min(oldOrigin.y, max(0, documentHeight - viewportHeight))))
        if revealSelection, !tiles.isEmpty {
            gridView.scrollToVisible(tiles[selectedIndex].frame)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isLayingOut = false
        didScroll()
    }

    private func updateMaterial() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        effectView.material = reduceTransparency ? .windowBackground : .hudWindow
        effectView.blendingMode = reduceTransparency ? .withinWindow : .behindWindow
    }

    private func registerSurface() {
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
    }

    private func layoutTiles(
        _ items: [WindowSwitcherItem],
        content: Content,
        size: CGSize
    ) {
        var previous = Dictionary(uniqueKeysWithValues: tiles.map { ($0.handle.id, $0) })
        tiles = items.enumerated().map { index, item in
            let old = previous.removeValue(forKey: item.handle.id)
            let tile: WindowSwitcherTile
            if let old, old.matches(item, size: size, content: content) {
                tile = old
                tile.setSelected(item.handle.id == content.selected)
            } else {
                old?.updatePreview(nil)
                tile = WindowSwitcherTile(
                    item: item,
                    size: size,
                    selected: item.handle.id == content.selected,
                    content: content
                )
            }
            tile.frame.origin = CGPoint(
                x: CGFloat(index % columns) * (size.width + 12),
                y: CGFloat(index / columns) * (size.height + 12)
            )
            tile.onSelect = { [weak self] in self?.onSelect(item.handle.id) }
            tile.onClose = { [weak self] in self?.onClose(item.handle.id) }
            gridView.addSubview(tile)
            return tile
        }
        previous.values.forEach { $0.updatePreview(nil) }
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
        scopeButton.toolTip = String(localized: "Press S to toggle workspace scope")
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

    private func layoutEmptyState(size: CGSize) {
        let message = NSTextField(wrappingLabelWithString: String(localized: "No windows in this workspace"))
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        message.frame = CGRect(x: 16, y: size.height / 2 - 20, width: size.width - 32, height: 40)
        effectView.addSubview(message)
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
        items.removeAll()
        selected = nil
        gridView.subviews.forEach { $0.removeFromSuperview() }
        effectView.subviews.forEach { $0.removeFromSuperview() }
    }

    @objc private func toggleScope() {
        onToggleScope()
    }

    @objc private func didScroll() {
        guard !isLayingOut, isVisible else { return }
        let visible = gridView.visibleRect
        let displayed = zip(items, tiles).compactMap { item, tile -> WindowSwitcherItem? in
            if tile.frame.intersects(visible) { return item }
            tile.updatePreview(nil)
            return nil
        }
        onVisibleItemsChanged(displayed)
    }
}

@MainActor
private final class WindowSwitcherGridView: NSView {
    override var isFlipped: Bool {
        true
    }
}
