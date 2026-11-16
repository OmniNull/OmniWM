// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

final class TabRailTrackOverlayView: NSView {
    private static let selectionAnimationDuration: CFTimeInterval = 0.25

    private var railLayout = TabRailLayout.empty
    private var activeVisualIndex = 0
    private var hoveredVisualIndex: Int?
    private var railHovered = false
    private(set) var segmentLayers: [Int: CAShapeLayer] = [:]
    private var hasRenderedSegments = false
    private let motionPolicy: MotionPolicy

    init(frame frameRect: NSRect, motionPolicy: MotionPolicy) {
        self.motionPolicy = motionPolicy
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSegmentLayers(
            animateSelectionChange: false,
            preserveRunningPathAnimation: false,
            preserveRunningColorAnimation: false
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func update(
        layout: TabRailLayout,
        activeVisualIndex: Int,
        hoveredVisualIndex: Int?,
        railHovered: Bool
    ) {
        let activeChanged = hasRenderedSegments && self.activeVisualIndex != activeVisualIndex
        let hoverChanged = self.hoveredVisualIndex != hoveredVisualIndex || self.railHovered != railHovered
        let layoutChanged = railLayout != layout
        guard layoutChanged || activeChanged || hoverChanged else { return }
        let layersChanged = railLayout.items.map(\.visualIndex) != layout.items.map(\.visualIndex)
        let geometryStable = railLayout.railRect == layout.railRect
            && railLayout.barRect == layout.barRect && !layersChanged

        railLayout = layout
        self.activeVisualIndex = activeVisualIndex
        self.hoveredVisualIndex = hoveredVisualIndex
        self.railHovered = railHovered

        if layersChanged {
            rebuildSegmentLayers()
        }
        updateSegmentLayers(
            animateSelectionChange: activeChanged
                && geometryStable
                && motionPolicy.animationsEnabled,
            preserveRunningPathAnimation: !activeChanged && geometryStable,
            preserveRunningColorAnimation: !activeChanged && !hoverChanged && geometryStable
        )
        hasRenderedSegments = !layout.items.isEmpty
        needsDisplay = true
    }

    func presentedMarkerRects() -> [Int: CGRect] {
        var rects: [Int: CGRect] = [:]
        rects.reserveCapacity(railLayout.items.count)
        for item in railLayout.items {
            if let path = segmentLayers[item.visualIndex]?.presentation()?.path {
                rects[item.visualIndex] = path.boundingBoxOfPath.offsetBy(
                    dx: railLayout.barRect.minX,
                    dy: railLayout.barRect.minY
                )
            } else {
                rects[item.visualIndex] = item.pillRect
            }
        }
        return rects
    }

    func visualIndex(at point: CGPoint) -> Int? {
        guard railLayout.railRect.contains(point) else { return nil }
        var previous: (visualIndex: Int, midY: CGFloat)?
        for index in railLayout.items.indices {
            let item = railLayout.items[index]
            let marker: CGRect
            if let path = segmentLayers[item.visualIndex]?.presentation()?.path {
                marker = path.boundingBoxOfPath.offsetBy(
                    dx: railLayout.barRect.minX, dy: railLayout.barRect.minY
                )
            } else {
                marker = item.pillRect
            }
            if let previous, point.y >= (previous.midY + marker.midY) / 2 {
                return previous.visualIndex
            }
            previous = (item.visualIndex, marker.midY)
        }
        return previous?.visualIndex
    }

    func refreshAppearance() {
        updateSegmentLayers(
            animateSelectionChange: false,
            preserveRunningPathAnimation: false,
            preserveRunningColorAnimation: false
        )
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        let localBounds = bounds.insetBy(
            dx: TabRailMetrics.trackBorderWidth / 2,
            dy: TabRailMetrics.trackBorderWidth / 2
        )
        if railHovered {
            TabRailMetrics.hoverColor.setFill()
            NSBezierPath(
                roundedRect: localBounds,
                xRadius: TabRailMetrics.trackCornerRadius,
                yRadius: TabRailMetrics.trackCornerRadius
            ).fill()
        }

        TabRailMetrics.trackBorderColor.setStroke()
        let border = NSBezierPath(
            roundedRect: localBounds,
            xRadius: TabRailMetrics.trackCornerRadius,
            yRadius: TabRailMetrics.trackCornerRadius
        )
        border.lineWidth = TabRailMetrics.trackBorderWidth
        border.stroke()
    }

    private func rebuildSegmentLayers() {
        for segmentLayer in segmentLayers.values {
            segmentLayer.removeAllAnimations()
            segmentLayer.removeFromSuperlayer()
        }
        segmentLayers.removeAll(keepingCapacity: true)

        for item in railLayout.items {
            let segmentLayer = CAShapeLayer()
            segmentLayer.actions = [
                "path": NSNull(),
                "fillColor": NSNull(),
                "bounds": NSNull(),
                "position": NSNull()
            ]
            layer?.addSublayer(segmentLayer)
            segmentLayers[item.visualIndex] = segmentLayer
        }
    }

    private func updateSegmentLayers(
        animateSelectionChange: Bool,
        preserveRunningPathAnimation: Bool,
        preserveRunningColorAnimation: Bool
    ) {
        guard !railLayout.items.isEmpty else { return }
        let clampedActiveIndex = min(max(0, activeVisualIndex), railLayout.items.count - 1)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let startTime = CACurrentMediaTime()

        for item in railLayout.items {
            guard let segmentLayer = segmentLayers[item.visualIndex] else { continue }
            let rect = item.pillRect.offsetBy(dx: -railLayout.barRect.minX, dy: -railLayout.barRect.minY)
            let selected = item.visualIndex == clampedActiveIndex
            let hovered = hoveredVisualIndex == item.visualIndex
            let targetPath = CGPath(
                roundedRect: rect,
                cornerWidth: TabRailMetrics.segmentCornerRadius,
                cornerHeight: TabRailMetrics.segmentCornerRadius,
                transform: nil
            )
            let color = selected
                ? TabRailMetrics.selectedColor(hovered: hovered)
                : TabRailMetrics.unselectedColor(hovered: hovered, railHovered: railHovered)
            let targetColor = color.usingColorSpace(.deviceRGB)?.cgColor ?? color.cgColor
            let presentation = segmentLayer.presentation()
            let fromPath = presentation?.path ?? segmentLayer.path
            let fromColor = presentation?.fillColor ?? segmentLayer.fillColor

            if !preserveRunningPathAnimation {
                segmentLayer.removeAnimation(forKey: "selection.path")
            }
            if !preserveRunningColorAnimation {
                segmentLayer.removeAnimation(forKey: "selection.color")
            }
            segmentLayer.frame = bounds
            segmentLayer.contentsScale = scale
            segmentLayer.path = targetPath
            segmentLayer.fillColor = targetColor

            guard animateSelectionChange, let fromPath, let fromColor else { continue }
            let timing = CAMediaTimingFunction(name: .easeInEaseOut)
            let pathAnimation = CABasicAnimation(keyPath: "path")
            pathAnimation.fromValue = fromPath
            pathAnimation.toValue = targetPath
            pathAnimation.duration = Self.selectionAnimationDuration
            pathAnimation.beginTime = segmentLayer.convertTime(startTime, from: nil)
            pathAnimation.timingFunction = timing
            segmentLayer.add(pathAnimation, forKey: "selection.path")

            let colorAnimation = CABasicAnimation(keyPath: "fillColor")
            colorAnimation.fromValue = fromColor
            colorAnimation.toValue = targetColor
            colorAnimation.duration = Self.selectionAnimationDuration
            colorAnimation.beginTime = segmentLayer.convertTime(startTime, from: nil)
            colorAnimation.timingFunction = timing
            segmentLayer.add(colorAnimation, forKey: "selection.color")
        }
    }
}
