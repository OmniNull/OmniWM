// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension MouseEventHandler {
    func liveDragReference(_ location: CGPoint) -> CGPoint {
        guard state.liveTabPull == nil,
              state.liveEdgeScroll == nil,
              let offset = state.liveDragReferenceOffset
        else { return location }
        guard let display = controller?.workspaceManager.monitors.first(where: { $0.frame.contains(location) })?.frame
        else { return CGPoint(x: location.x + offset, y: location.y) }
        let toEdge = max(0, min(location.x - display.minX, display.maxX - location.x))
        let ease = abs(offset) > 0 ? min(1, toEdge / abs(offset)) : 1
        let x = location.x + offset * ease
        return CGPoint(x: min(max(x, display.minX), display.maxX - 1), y: location.y)
    }

    func liveDragWindowMidX(_ location: CGPoint) -> CGFloat? {
        guard state.liveTabPull == nil, let offset = state.liveDragReferenceOffset else { return nil }
        return location.x + offset
    }

    func clearLiveDragReference() {
        state.liveDragReferenceOffset = nil
        state.livePointerSamples = []
    }

    func recordLivePointerSample(_ location: CGPoint) {
        let now = liveDragClock()
        let window = liveSlowDownConfiguration.liveSlowDownWindow
        state.livePointerSamples.append(.init(location: location, time: now))
        while state.livePointerSamples.count > 1, state.livePointerSamples[1].time <= now - window {
            state.livePointerSamples.removeFirst()
        }
    }

    func livePointerHasSlowed(at now: TimeInterval) -> Bool {
        let configuration = liveSlowDownConfiguration
        guard let current = state.livePointerSamples.last,
              let earlier = state.livePointerSamples.last(where: {
                  $0.time <= now - configuration.liveSlowDownWindow + 0.005
              })
        else { return false }
        let moved = hypot(current.location.x - earlier.location.x, current.location.y - earlier.location.y)
        return moved < configuration.liveSlowDownDistance
    }

    func livePointerStopCheckDelay(at now: TimeInterval) -> TimeInterval? {
        guard let last = state.livePointerSamples.last else { return nil }
        let delay = last.time + liveSlowDownConfiguration.liveSlowDownWindow - now
        return delay > 0.005 ? delay : nil
    }

    private var liveSlowDownConfiguration: MoveConfiguration {
        controller?.niriEngine?.moveConfiguration ?? .default
    }

    func pointerHasLeft(_ monitor: Monitor, at location: CGPoint) -> Bool {
        let monitors = controller?.workspaceManager.monitors ?? []
        if monitors.contains(where: { $0.id != monitor.id && $0.frame.contains(location) }) { return true }
        let frame = monitor.frame
        return location.x < frame.minX || location.x > frame.maxX
            || location.y < frame.minY || location.y > frame.maxY
    }
}
