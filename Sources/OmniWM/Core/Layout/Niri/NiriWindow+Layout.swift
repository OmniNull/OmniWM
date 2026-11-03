// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension NiriWindow {
    func applyLayout(
        _ layout: NiriWindowLayout,
        sizingMode: SizingMode,
        within geometry: NiriContainerLayoutFrames,
        at time: TimeInterval
    ) -> CGRect {
        switch sizingMode {
        case .fullscreen,
             .maximized:
            applyUnanimatedLayout(layout, within: geometry)
        case .normal:
            applyAnimatedLayout(layout, within: geometry, at: time)
        }
    }

    private func applyUnanimatedLayout(
        _ layout: NiriWindowLayout,
        within geometry: NiriContainerLayoutFrames
    ) -> CGRect {
        applyResolvedLayout(layout, orientation: geometry.orientation)
        return applyRenderedFrame(layout.renderedBaseFrame, within: geometry)
    }

    private func applyAnimatedLayout(
        _ layout: NiriWindowLayout,
        within geometry: NiriContainerLayoutFrames,
        at time: TimeInterval
    ) -> CGRect {
        applyResolvedLayout(layout, orientation: geometry.orientation)
        let frame = animatedFrame(
            from: layout.renderedBaseFrame,
            within: geometry.renderedRect,
            at: time,
            orientation: geometry.orientation
        )
        return applyRenderedFrame(frame, within: geometry)
    }

    private func applyResolvedLayout(_ layout: NiriWindowLayout, orientation: Monitor.Orientation) {
        frame = layout.frame
        switch orientation {
        case .horizontal:
            resolvedHeight = layout.resolvedSpan
        case .vertical:
            resolvedWidth = layout.resolvedSpan
        }
    }

    private func applyRenderedFrame(
        _ frame: CGRect,
        within geometry: NiriContainerLayoutFrames
    ) -> CGRect {
        let clampedFrame = NiriMonitorPlaneGeometry.clampedFrame(
            frame,
            screenClampRect: geometry.viewFrame,
            orientation: geometry.orientation
        )
        let roundedFrame = clampedFrame.roundedToPhysicalPixels(scale: geometry.scale)
        renderedFrame = roundedFrame
        return roundedFrame
    }

    func animatedFrame(
        from renderedBaseFrame: CGRect,
        within containerRect: CGRect,
        at time: TimeInterval,
        orientation: Monitor.Orientation
    ) -> CGRect {
        let windowOffset = renderOffset(at: time)
        var offsetFrame = renderedBaseFrame.offsetBy(dx: windowOffset.x, dy: windowOffset.y)
        switch orientation {
        case .horizontal:
            let minY = containerRect.minY
            let maxY = containerRect.maxY - offsetFrame.height
            if maxY >= minY {
                offsetFrame.origin.y = min(max(offsetFrame.origin.y, minY), maxY)
            }
        case .vertical:
            let minX = containerRect.minX
            let maxX = containerRect.maxX - offsetFrame.width
            if maxX >= minX {
                offsetFrame.origin.x = min(max(offsetFrame.origin.x, minX), maxX)
            }
            if let containmentFrame = moveYContainmentFrame,
               renderedBaseFrame.minY >= containmentFrame.minY,
               renderedBaseFrame.maxY <= containmentFrame.maxY
            {
                let minY = containmentFrame.minY
                let maxY = containmentFrame.maxY - offsetFrame.height
                if maxY >= minY {
                    offsetFrame.origin.y = min(max(offsetFrame.origin.y, minY), maxY)
                }
            }
        }
        return offsetFrame
    }
}
