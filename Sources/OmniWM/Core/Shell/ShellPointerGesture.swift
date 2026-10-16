// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import OmniWMShellCore

struct ShellPointerGesture {
    struct Candidate {
        let handle: ElementHandle
        let configuration: ShellGestureConfig
        var lockedAxis: ShellGestureConfig.Axis?
    }

    struct Sample {
        let handle: ElementHandle
        let phase: ShellEvent.Phase
        let axis: ShellGestureConfig.Axis
        let translation: CGPoint
        let velocity: CGPoint
        let committed: Bool
    }

    private(set) var candidates: [Candidate]
    let origin: CGPoint
    let source: ShellGestureConfig.Source
    private(set) var selected: Candidate?
    private var position: CGPoint
    private var timestamp: Double
    private var velocityOrigin: CGPoint
    private var velocityTimestamp: Double

    var canClaim: Bool {
        guard selected == nil else { return true }
        return candidates.contains {
            switch $0.configuration.axis {
            case .none: false
            case .free,
                 .auto: true
            case .x,
                 .y: $0.lockedAxis == nil || $0.configuration.axis == $0.lockedAxis
            }
        }
    }

    init(candidates: [Candidate], origin: CGPoint, source: ShellGestureConfig.Source, timestamp: Double) {
        self.candidates = candidates
        self.origin = origin
        self.source = source
        position = origin
        self.timestamp = timestamp
        velocityOrigin = origin
        velocityTimestamp = timestamp
    }

    mutating func update(at point: CGPoint, timestamp: Double) -> Sample? {
        velocityOrigin = position
        velocityTimestamp = self.timestamp
        position = point
        self.timestamp = max(timestamp, self.timestamp)
        let translation = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        if let selected {
            guard selected.configuration.eventsAll else { return nil }
            return sample(selected, phase: .changed, at: point, timestamp: timestamp)
        }
        let x = abs(translation.x)
        let y = abs(translation.y)
        for index in candidates.indices.reversed() {
            var candidate = candidates[index]
            let configuration = candidate.configuration
            if candidate.lockedAxis == nil,
               max(x, y) > CGFloat(configuration.lockDistance),
               max(x, y) >= min(x, y) * CGFloat(configuration.dominance)
            {
                candidate.lockedAxis = x >= y ? .x : .y
                candidates[index].lockedAxis = candidate.lockedAxis
            }
            guard Self.accepts(translation, axis: candidate.lockedAxis, configuration: configuration) else { continue }
            selected = candidate
            return sample(candidate, phase: .began, at: point, timestamp: timestamp)
        }
        return nil
    }

    var trackingSample: Sample? {
        selected.map { sample($0, phase: .changed, at: position, timestamp: timestamp) }
    }

    func end(at point: CGPoint, timestamp: Double, cancelled: Bool = false) -> Sample? {
        guard let selected else { return nil }
        return sample(selected, phase: cancelled ? .cancelled : .ended, at: point, timestamp: timestamp)
    }

    private func sample(
        _ candidate: Candidate,
        phase: ShellEvent.Phase,
        at point: CGPoint,
        timestamp: Double
    ) -> Sample {
        let translation = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        let elapsed = timestamp - velocityTimestamp
        let velocity = elapsed > 0 ? CGPoint(
            x: (point.x - velocityOrigin.x) / elapsed,
            y: (point.y - velocityOrigin.y) / elapsed
        ) : .zero
        return Sample(
            handle: candidate.handle,
            phase: phase,
            axis: candidate.configuration.axis == .free ? .free : candidate.lockedAxis ?? candidate.configuration.axis,
            translation: translation,
            velocity: velocity,
            committed: phase == .ended && Self.commits(
                translation,
                velocity: velocity,
                configuration: candidate.configuration
            )
        )
    }

    static func accepts(
        _ translation: CGPoint,
        axis: ShellGestureConfig.Axis?,
        configuration: ShellGestureConfig
    ) -> Bool {
        let x = abs(translation.x)
        let y = abs(translation.y)
        let threshold = CGFloat(configuration.threshold)
        switch configuration.axis {
        case .none: return false
        case .free: return hypot(x, y) >= threshold
        case .x: return axis == .x && x >= threshold
        case .y: return axis == .y && y >= threshold
        case .auto: return axis != nil && max(x, y) >= threshold
        }
    }

    static func commits(_ translation: CGPoint, velocity: CGPoint, configuration: ShellGestureConfig) -> Bool {
        let distance: CGFloat
        let speed: CGFloat
        switch configuration.direction {
        case .left: (distance, speed) = (-translation.x, -velocity.x)
        case .right: (distance, speed) = (translation.x, velocity.x)
        case .up: (distance, speed) = (-translation.y, -velocity.y)
        case .down: (distance, speed) = (translation.y, velocity.y)
        case .any:
            switch configuration.axis {
            case .x: (distance, speed) = (abs(translation.x), abs(velocity.x))
            case .y: (distance, speed) = (abs(translation.y), abs(velocity.y))
            case .none: return false
            case .auto,
                 .free: (distance, speed) = (hypot(translation.x, translation.y), hypot(velocity.x, velocity.y))
            }
        }
        return configuration.commitDistance > 0 && distance >= CGFloat(configuration.commitDistance)
            || configuration.commitVelocity > 0 && speed >= CGFloat(configuration.commitVelocity)
    }
}
