// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore
import QuartzCore

extension ShellWidgetSurface {
    @discardableResult
    func beginGesture(at point: CGPoint, source: ShellGestureConfig.Source, timestamp: TimeInterval) -> Bool {
        let candidates = layout.core.hitPath(x: Float(point.x), y: Float(point.y), matching: {
            ($0.gestureAction != 0 || $0.gestureTrack != 0) && $0.gesture.axis != .none
                && ($0.gesture.source == source || $0.gesture.source == .both)
        }, clip: clips).map {
            ShellPointerGesture.Candidate(handle: $0, configuration: layout.core.content(of: $0).gesture)
        }
        guard !candidates.isEmpty else { return false }
        gesturePosition = source == .scroll ? .zero : point
        gesturePointer = point
        pointerGesture = ShellPointerGesture(
            candidates: candidates,
            origin: gesturePosition,
            source: source,
            timestamp: timestamp
        )
        return true
    }

    @discardableResult
    func updateGesture(at point: CGPoint, timestamp: TimeInterval, event: ShellEvent) -> Bool {
        guard var gesture = pointerGesture else { return false }
        pointerGesture = nil
        gesturePosition = point
        let sample = gesture.update(at: point, timestamp: timestamp)
        pointerGesture = gesture
        if let sample {
            if sample.phase == .began {
                guard layout.core.contains(sample.handle) else {
                    pointerGesture = nil
                    return false
                }
                finishPress(at: gesturePointer, event: pressCapture?.event ?? event, cancelled: true)
                dragStart = nil
                gestureCapture = capture(sample.handle, event: event)
            }
            trackGesture(sample)
            emitGesture(sample, event: event)
        } else if gestureTracking != nil, let sample = gesture.trackingSample {
            trackGesture(sample)
        }
        return gesture.selected != nil
    }

    @discardableResult
    func finishGesture(
        at point: CGPoint,
        timestamp: TimeInterval,
        cancelled: Bool = false,
        event: ShellEvent? = nil
    ) -> Bool {
        let gesture = pointerGesture
        let capture = gestureCapture
        pointerGesture = nil
        gestureCapture = nil
        guard let gesture, let capture,
              let sample = gesture.end(at: point, timestamp: timestamp, cancelled: cancelled) else { return false }
        let token = finishGestureTrack(sample, invokesAction: capture.content.gestureAction != 0)
        emitGesture(sample, capture: capture, event: event ?? capture.event, trackingToken: token)
        return true
    }

    private func emitGesture(
        _ sample: ShellPointerGesture.Sample,
        capture: ShellPointerCapture? = nil,
        event: ShellEvent,
        trackingToken: UInt64? = nil
    ) {
        guard let capture = capture ?? gestureCapture else { return }
        var event = event
        event.kind = .gesture
        event.phase = sample.phase
        event.dx = Double(sample.translation.x)
        event.dy = Double(sample.translation.y)
        event.vx = Double(sample.velocity.x)
        event.vy = Double(sample.velocity.y)
        event.committed = sample.committed
        event.trackingToken = trackingToken
        emit(capture.content.gestureAction, capture: capture, point: gesturePointer, event: event)
    }

    func scrollGesture(at point: CGPoint, event: ShellEvent, timestamp: TimeInterval) -> Bool {
        guard event.momentum == .none else { return false }
        if event.phase == .began, pointerGesture?.source == .scroll {
            finishGesture(at: gesturePosition, timestamp: timestamp, cancelled: true, event: event)
        }
        if pointerGesture == nil {
            guard event.phase != .ended, event.phase != .cancelled,
                  beginGesture(at: point, source: .scroll, timestamp: timestamp) else { return false }
        }
        guard pointerGesture?.source == .scroll else { return false }
        gesturePointer = point
        if event.phase == .cancelled {
            return finishGesture(at: gesturePosition, timestamp: timestamp, cancelled: true, event: event)
        }
        let next = CGPoint(x: gesturePosition.x + CGFloat(event.dx), y: gesturePosition.y + CGFloat(event.dy))
        if event.phase == .ended {
            if pointerGesture?.selected == nil { _ = updateGesture(at: next, timestamp: timestamp, event: event) }
            return finishGesture(at: next, timestamp: timestamp, event: event)
        }
        guard pointerGesture?.canClaim != false else { return false }
        let claimed = updateGesture(at: next, timestamp: timestamp, event: event)
        let canClaim = pointerGesture?.canClaim == true
        if event.phase == nil { _ = finishGesture(at: next, timestamp: timestamp, event: event) }
        return claimed || event.phase != nil && canClaim
    }
}
