// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

final class TabRailIconView: NSVisualEffectView {
    let scrollView = NSScrollView()
    private let document = TabRailIconDocumentView()
    private let motionPolicy: MotionPolicy
    private let appInfoCache: AppInfoCache
    private var tokens: [WindowToken?] = []
    private(set) var rows: [TabRailIconRowView] = []
    private var activeVisualIndex = 0
    private var hoveredVisualIndex: Int?
    var onWillScroll: (() -> Void)?
    var onDidScroll: (() -> Void)?

    init(motionPolicy: MotionPolicy, appInfoCache: AppInfoCache) {
        self.motionPolicy = motionPolicy
        self.appInfoCache = appInfoCache
        super.init(frame: .zero)
        state = .active
        wantsLayer = true
        layer?.cornerRadius = TabRailMetrics.trackCornerRadius
        layer?.masksToBounds = true
        let clip = scrollView.contentView
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: clip
        )
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = document
        addSubview(scrollView)
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func scrollWheel(with event: NSEvent) {
        onWillScroll?()
        scrollView.scrollWheel(with: event)
    }

    @objc private func clipBoundsChanged() {
        onWillScroll?()
        needsDisplay = true
        onDidScroll?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let wasEmpty = bounds.height == 0
        super.setFrameSize(newSize)
        scrollView.frame = bounds
        layoutRows()
        if wasEmpty, newSize.height > 0 { reveal(activeVisualIndex) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func update(tabs: [TabRailTabInfo], activeVisualIndex: Int) {
        let nextTokens = tabs.map(\.token)
        let membershipChanged = tokens != nextTokens || rows.count != tabs.count
        let activeChanged = self.activeVisualIndex != activeVisualIndex
        if membershipChanged {
            rebuildRows(tabs: tabs, tokens: nextTokens)
        }
        self.activeVisualIndex = activeVisualIndex
        updateSelection(animate: activeChanged && !membershipChanged)
        if membershipChanged || activeChanged {
            reveal(activeVisualIndex)
        }
    }

    func updateHover(_ visualIndex: Int?) {
        guard hoveredVisualIndex != visualIndex else { return }
        hoveredVisualIndex = visualIndex
        updateSelection(animate: false)
    }

    func reveal(_ visualIndex: Int) {
        guard rows.indices.contains(visualIndex) else { return }
        let rect = rows[visualIndex].frame
        let visible = scrollView.contentView.bounds
        var origin = visible.origin
        if rect.height > visible.height {
            origin.y = rect.midY - visible.height / 2
        } else if rect.minY < visible.minY {
            origin.y = rect.minY
        } else if rect.maxY > visible.maxY {
            origin.y = rect.maxY - visible.height
        }
        scroll(to: origin)
    }

    func railLayout(in view: NSView) -> TabRailLayout {
        let viewport = convert(bounds, to: view)
        let items = rows.enumerated().map { index, row in
            let hit = document.convert(row.frame, to: view).intersection(viewport)
            let icon = row.convert(row.imageView.frame, to: view).intersection(viewport)
            return TabRailLayout.Item(
                visualIndex: index,
                hitRect: hit.isNull ? .zero : hit,
                pillRect: icon.isNull ? (hit.isNull ? .zero : hit) : icon
            )
        }
        return TabRailLayout(railRect: viewport, barRect: viewport, items: items)
    }

    func refreshAppearance() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        material = reduceTransparency ? .windowBackground : .hudWindow
        blendingMode = reduceTransparency ? .withinWindow : .behindWindow
        layer?.backgroundColor = reduceTransparency ? NSColor.windowBackgroundColor.cgColor : NSColor.clear.cgColor
        layer?.borderColor = TabRailMetrics.trackBorderColor.cgColor
        layer?.borderWidth = TabRailMetrics.trackBorderWidth
        for row in rows { row.refreshAppearance() }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let visible = scrollView.contentView.bounds
        NSColor.labelColor.withAlphaComponent(0.7).setStroke()
        if visible.minY > 0 {
            drawEdgeCue(at: bounds.maxY - 2, direction: -1)
        }
        if visible.maxY < document.bounds.height {
            drawEdgeCue(at: bounds.minY + 2, direction: 1)
        }
    }

    private func drawEdgeCue(at y: CGFloat, direction: CGFloat) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: bounds.midX - 3, y: y + direction * 2))
        path.line(to: CGPoint(x: bounds.midX, y: y))
        path.line(to: CGPoint(x: bounds.midX + 3, y: y + direction * 2))
        path.lineWidth = 1
        path.stroke()
    }

    private func rebuildRows(tabs: [TabRailTabInfo], tokens nextTokens: [WindowToken?]) {
        var reusable: [WindowToken: TabRailIconRowView] = [:]
        for (token, row) in zip(tokens, rows) {
            if let token { reusable[token] = row }
            row.removeFromSuperview()
        }
        tokens = nextTokens
        rows = tabs.map { tab in
            let row = tab.token.flatMap { reusable.removeValue(forKey: $0) }
                ?? TabRailIconRowView(
                    image: tab.icon ?? tab.token.flatMap { appInfoCache.info(for: $0.pid)?.icon },
                    motionPolicy: motionPolicy
                )
            document.addSubview(row)
            return row
        }
        layoutRows()
    }

    private func layoutRows() {
        let rowHeight = TabRailStyle.iconRowHeight
        document.setFrameSize(CGSize(width: bounds.width, height: CGFloat(rows.count) * rowHeight))
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
        }
        scroll(to: scrollView.contentView.bounds.origin)
    }

    private func scroll(to origin: CGPoint) {
        let clip = scrollView.contentView
        let maxOffset = max(0, document.bounds.height - clip.bounds.height)
        onWillScroll?()
        clip.scroll(to: CGPoint(x: 0, y: min(max(0, origin.y), maxOffset)))
        scrollView.reflectScrolledClipView(clip)
    }

    private func updateSelection(animate: Bool) {
        for (index, row) in rows.enumerated() {
            row.update(selected: index == activeVisualIndex, hovered: index == hoveredVisualIndex, animate: animate)
        }
    }
}

private final class TabRailIconDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}
