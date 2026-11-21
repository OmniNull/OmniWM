// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

final class TabRailTrackView: NSVisualEffectView {
    private let overlayView: TabRailTrackOverlayView

    init(frame frameRect: NSRect, motionPolicy: MotionPolicy) {
        overlayView = TabRailTrackOverlayView(frame: .zero, motionPolicy: motionPolicy)
        super.init(frame: frameRect)
        state = .active
        wantsLayer = true
        layer?.cornerRadius = TabRailMetrics.trackCornerRadius
        layer?.masksToBounds = true
        overlayView.frame = bounds
        overlayView.autoresizingMask = [.width, .height]
        addSubview(overlayView)
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    func presentedMarkerRects() -> [Int: CGRect] {
        overlayView.presentedMarkerRects()
    }

    func visualIndex(at point: CGPoint) -> Int? {
        overlayView.visualIndex(at: point)
    }

    func update(
        layout: TabRailLayout,
        activeVisualIndex: Int,
        hoveredVisualIndex: Int?,
        railHovered: Bool
    ) {
        overlayView.update(
            layout: layout,
            activeVisualIndex: activeVisualIndex,
            hoveredVisualIndex: hoveredVisualIndex,
            railHovered: railHovered
        )
    }

    func refreshAppearance() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        material = reduceTransparency ? .windowBackground : .hudWindow
        blendingMode = reduceTransparency ? .withinWindow : .behindWindow
        layer?.backgroundColor = reduceTransparency
            ? NSColor.windowBackgroundColor.cgColor
            : NSColor.clear.cgColor
        overlayView.refreshAppearance()
    }
}
