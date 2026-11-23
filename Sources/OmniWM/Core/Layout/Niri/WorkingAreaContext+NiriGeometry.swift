// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

enum ContainerVisibilityState {
    case visible
    case hidden(AxisHideEdge)
}

extension WorkingAreaContext {
    func settledRenderedContainerRect(
        _ rect: CGRect,
        contentFrame: CGRect,
        orientation: Monitor.Orientation
    ) -> CGRect {
        var frame = rect
        switch orientation {
        case .horizontal:
            if frame.maxX <= contentFrame.minX {
                frame.origin.x += viewFrame.minX - frame.maxX
            } else if frame.minX >= contentFrame.maxX {
                frame.origin.x += viewFrame.maxX - frame.minX
            } else {
                return frame
            }
        case .vertical:
            if frame.maxY <= contentFrame.minY {
                frame.origin.y += viewFrame.minY - frame.maxY
            } else if frame.minY >= contentFrame.maxY {
                frame.origin.y += viewFrame.maxY - frame.minY
            } else {
                return frame
            }
        }
        return NiriMonitorPlaneGeometry.clampedFrame(
            frame,
            screenClampRect: viewFrame,
            orientation: orientation
        )
    }

    func canonicalContainerRect(
        position: CGFloat,
        span: CGFloat,
        orientation: Monitor.Orientation
    ) -> CGRect {
        switch orientation {
        case .horizontal:
            let width = span.roundedToPhysicalPixel(scale: scale)
            return CGRect(
                x: workingFrame.origin.x + position,
                y: workingFrame.origin.y,
                width: width,
                height: workingFrame.height
            ).roundedToPhysicalPixels(scale: scale)
        case .vertical:
            let height = span.roundedToPhysicalPixel(scale: scale)
            return CGRect(
                x: workingFrame.origin.x,
                y: workingFrame.origin.y + position,
                width: workingFrame.width,
                height: height
            ).roundedToPhysicalPixels(scale: scale)
        }
    }

    func visibleRenderedContainerRect(
        canonicalRect: CGRect,
        viewPosition: CGFloat,
        workspaceOffset: CGFloat,
        renderOffset: CGPoint,
        orientation: Monitor.Orientation
    ) -> CGRect {
        let translation: CGPoint = switch orientation {
        case .horizontal:
            CGPoint(
                x: -viewPosition + workspaceOffset + renderOffset.x,
                y: renderOffset.y
            )
        case .vertical:
            CGPoint(
                x: workspaceOffset + renderOffset.x,
                y: -viewPosition + renderOffset.y
            )
        }
        return canonicalRect.offsetBy(dx: translation.x, dy: translation.y)
            .roundedToPhysicalPixels(scale: scale)
    }

    func hiddenEdge(
        for renderedRect: CGRect,
        fallback: AxisHideEdge,
        orientation: Monitor.Orientation
    ) -> AxisHideEdge {
        switch orientation {
        case .horizontal:
            let leftOverflow = workingFrame.minX - renderedRect.minX
            let rightOverflow = renderedRect.maxX - workingFrame.maxX
            if leftOverflow > rightOverflow, leftOverflow > 0 {
                return .minimum
            }
            if rightOverflow > leftOverflow, rightOverflow > 0 {
                return .maximum
            }
        case .vertical:
            let topOverflow = workingFrame.minY - renderedRect.minY
            let bottomOverflow = renderedRect.maxY - workingFrame.maxY
            if topOverflow > bottomOverflow, topOverflow > 0 {
                return .minimum
            }
            if bottomOverflow > topOverflow, bottomOverflow > 0 {
                return .maximum
            }
        }
        return fallback
    }

    func hiddenRenderedContainerRect(
        canonicalRect: CGRect,
        edge: AxisHideEdge,
        orientation: Monitor.Orientation,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]
    ) -> CGRect {
        if let hiddenPlacementMonitor {
            let orthogonalOrigin: CGFloat = switch orientation {
            case .horizontal: canonicalRect.minY
            case .vertical: canonicalRect.minX
            }
            return HiddenWindowPlacementResolver(
                monitor: hiddenPlacementMonitor,
                monitors: hiddenPlacementMonitors
            ).placement(
                for: canonicalRect.size,
                requestedEdge: edge,
                orthogonalOrigin: orthogonalOrigin,
                baseReveal: 1.0,
                orientation: orientation
            )
            .frame(for: canonicalRect.size)
            .roundedToPhysicalPixels(scale: scale)
        }

        switch orientation {
        case .horizontal:
            return hiddenColumnRect(
                canonicalRect,
                edge: edge,
                edgeFrame: viewFrame,
                scale: scale
            ).roundedToPhysicalPixels(scale: scale)
        case .vertical:
            return hiddenRowRect(
                canonicalRect,
                edge: edge,
                edgeFrame: viewFrame,
                scale: scale
            ).roundedToPhysicalPixels(scale: scale)
        }
    }

    private func hiddenRowRect(
        _ rect: CGRect,
        edge: AxisHideEdge,
        edgeFrame: CGRect,
        scale: CGFloat
    ) -> CGRect {
        let edgeReveal = 1.0 / max(1.0, scale)
        let y: CGFloat
        switch edge {
        case .minimum:
            y = edgeFrame.minY - rect.height + edgeReveal
        case .maximum:
            y = edgeFrame.maxY - edgeReveal
        }
        let origin = CGPoint(x: rect.minX, y: y)
        return CGRect(origin: origin, size: CGSize(width: rect.width, height: rect.height))
    }

    private func hiddenColumnRect(
        _ rect: CGRect,
        edge: AxisHideEdge,
        edgeFrame: CGRect,
        scale: CGFloat
    ) -> CGRect {
        let edgeReveal = 1.0 / max(1.0, scale)
        let x: CGFloat
        switch edge {
        case .minimum:
            x = edgeFrame.minX - rect.width + edgeReveal
        case .maximum:
            x = edgeFrame.maxX - edgeReveal
        }
        let origin = CGPoint(x: x, y: rect.minY)
        return CGRect(origin: origin, size: CGSize(width: rect.width, height: rect.height))
    }
}
