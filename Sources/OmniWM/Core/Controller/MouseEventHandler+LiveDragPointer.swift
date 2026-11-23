// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension MouseEventHandler {
    func liveDragReference(_ location: CGPoint, orientation: Monitor.Orientation = .horizontal) -> CGPoint {
        guard liveDragSession?.carriedWindow == nil || state.gestureOwnsWindowInteraction,
              liveDragSession?.edgeScroll == nil,
              let offset = liveDragSession?.referenceOffset
        else { return location }
        let primary = orientation == .horizontal ? location.x : location.y
        var adjusted = primary + offset
        if let display = controller?.workspaceManager.monitors.first(where: { $0.frame.contains(location) })?.frame {
            let start = orientation == .horizontal ? display.minX : display.minY
            let end = orientation == .horizontal ? display.maxX : display.maxY
            let toEdge = max(0, min(primary - start, end - primary))
            let ease = abs(offset) > 0 ? min(1, toEdge / abs(offset)) : 1
            adjusted = min(max(primary + offset * ease, start), end - 1)
        }
        return orientation == .horizontal
            ? CGPoint(x: adjusted, y: location.y)
            : CGPoint(x: location.x, y: adjusted)
    }

    func liveDragWindowMidX(_ location: CGPoint, orientation: Monitor.Orientation = .horizontal) -> CGFloat? {
        guard liveDragSession?.carriedWindow == nil || state.gestureOwnsWindowInteraction,
              let offset = liveDragSession?.referenceOffset else { return nil }
        return (orientation == .horizontal ? location.x : location.y) + offset
    }

    func recordLivePointerSample(_ location: CGPoint) {
        let now = liveDragClock()
        let window = MoveConfiguration.liveSlowDownWindow
        livePointer.samples.append(.init(location: location, time: now))
        while livePointer.samples.count > 1, livePointer.samples[1].time <= now - window {
            livePointer.samples.removeFirst()
        }
    }

    func livePointerHasSlowed(at now: TimeInterval) -> Bool {
        guard let current = livePointer.samples.last,
              let earlier = livePointer.samples.last(where: {
                  $0.time <= now - MoveConfiguration.liveSlowDownWindow + 0.005
              })
        else { return false }
        let moved = hypot(current.location.x - earlier.location.x, current.location.y - earlier.location.y)
        return moved < MoveConfiguration.liveSlowDownDistance
    }

    func livePointerStopCheckDelay(at now: TimeInterval) -> TimeInterval? {
        guard let last = livePointer.samples.last else { return nil }
        let delay = last.time + MoveConfiguration.liveSlowDownWindow - now
        return delay > 0.005 ? delay : nil
    }

    func pointerHasLeft(_ monitor: Monitor, at location: CGPoint) -> Bool {
        let monitors = controller?.workspaceManager.monitors ?? []
        if monitors.contains(where: { $0.id != monitor.id && $0.frame.contains(location) }) { return true }
        let frame = monitor.frame
        return location.x < frame.minX || location.x > frame.maxX
            || location.y < frame.minY || location.y > frame.maxY
    }
}
