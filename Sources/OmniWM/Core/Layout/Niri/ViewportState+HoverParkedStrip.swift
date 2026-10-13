// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

enum NiriHoverParkedStrip {
    static func isParkedStrip(
        frame: CGRect,
        monitorFrame: CGRect,
        orientation: Monitor.Orientation,
        scale: CGFloat
    ) -> Bool {
        let (frameStart, frameEnd, monitorStart, monitorEnd) = switch orientation {
        case .horizontal:
            (frame.minX, frame.maxX, monitorFrame.minX, monitorFrame.maxX)
        case .vertical:
            (frame.minY, frame.maxY, monitorFrame.minY, monitorFrame.maxY)
        }
        let visibleLength = max(0, min(frameEnd, monitorEnd) - max(frameStart, monitorStart))
        let roundingTolerance = 0.5 / max(scale, 1)
        return visibleLength <= LayoutRefreshController.hiddenWindowEdgeRevealEpsilon + roundingTolerance
    }
}
