// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

enum StopWindowGeometry {
    enum Placement: Sendable {
        case topLeft(CGPoint)
        case floatingOrigin(CGPoint)
        case floatingNormalizedOrigin(CGPoint)
    }

    static func isOnscreen(_ frame: CGRect, monitors: [Monitor]) -> Bool {
        monitors.contains {
            let overlap = $0.frame.intersection(frame)
            return overlap.width > 1 && overlap.height > 1
        }
    }

    static func placement(
        floating: FloatingState?, hidden: HiddenState?, monitor: Monitor?, fallbackFrame: CGRect? = nil
    ) -> Placement? {
        if let floating {
            if floating.referenceMonitorId != monitor?.id, let normalized = floating.normalizedOrigin {
                return .floatingNormalizedOrigin(normalized)
            }
            return .floatingOrigin(floating.lastFrame.origin)
        }
        if let hidden, let monitor {
            return .topLeft(CGPoint(
                x: monitor.frame.minX + monitor.frame.width * min(max(hidden.proportionalPosition.x, 0), 1),
                y: monitor.frame.maxY - monitor.frame.height * min(max(hidden.proportionalPosition.y, 0), 1)
            ))
        }
        return fallbackFrame.map { .topLeft($0.topLeftCorner) }
    }

    static func destination(
        for currentFrame: CGRect, in visibleFrame: CGRect?, placement: Placement?
    ) -> CGRect? {
        guard let visibleFrame else { return nil }
        let point: CGPoint
        switch placement {
        case let .topLeft(topLeft): point = topLeft
        case let .floatingOrigin(origin): point = CGPoint(x: origin.x, y: origin.y + currentFrame.height)
        case let .floatingNormalizedOrigin(normalized):
            let origin = FloatingFrameGeometry.origin(from: normalized, windowSize: currentFrame.size, in: visibleFrame)
            point = CGPoint(x: origin.x, y: origin.y + currentFrame.height)
        case nil: point = currentFrame.topLeftCorner
        }
        let x = min(max(point.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - currentFrame.width))
        let y = min(max(point.y, min(visibleFrame.maxY, visibleFrame.minY + currentFrame.height)), visibleFrame.maxY)
        return CGRect(x: x, y: y - currentFrame.height, width: currentFrame.width, height: currentFrame.height)
    }
}
