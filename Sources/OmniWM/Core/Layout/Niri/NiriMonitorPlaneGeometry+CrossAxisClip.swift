// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

extension NiriMonitorPlaneGeometry {
    static func crossAxisClipped(
        _ rect: CGRect,
        to displayFrame: CGRect,
        orientation: Monitor.Orientation
    ) -> CGRect? {
        var clipped = rect
        switch orientation {
        case .horizontal:
            clipped.origin.y = max(rect.minY, displayFrame.minY)
            clipped.size.height = min(rect.maxY, displayFrame.maxY) - clipped.minY
            return clipped.height > 0 ? clipped : nil
        case .vertical:
            clipped.origin.x = max(rect.minX, displayFrame.minX)
            clipped.size.width = min(rect.maxX, displayFrame.maxX) - clipped.minX
            return clipped.width > 0 ? clipped : nil
        }
    }
}
