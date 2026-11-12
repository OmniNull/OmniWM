// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

final class WorkspaceSwipeMotion {
    static let travelUnits = 300.0
    static let progressBounds = -0.30 ... 1.30
    private static let resistance = 0.55
    private static let stretch = 0.30
    private static let projectionDecay = 1000 * log(0.997)
    static let springConfig = SpringConfig(
        dampingRatio: 1,
        stiffness: 1000,
        epsilon: 0.0001,
        velocityEpsilon: 0.01
    )

    private let tracker = SwipeTracker(historyLimit: 0.150)
    private var originUnits: Double
    private var baselineProgress = 0.0
    private var trackedProgress = 0.0
    private var lastTimestamp: TimeInterval
    private var spring: SpringAnimation?
    private(set) var target: Double?

    init(cumulativeUnits: Double, timestamp: TimeInterval, recognitionMovement: SwipeEvent? = nil) {
        originUnits = cumulativeUnits.isFinite ? cumulativeUnits : 0
        lastTimestamp = timestamp.isFinite ? timestamp : 0
        tracker.seed(recognitionMovement.map {
            SwipeEvent(delta: $0.delta / Self.travelUnits, timestamp: $0.timestamp)
        }, endingAt: lastTimestamp)
    }

    func progress(at timestamp: TimeInterval) -> Double {
        guard let spring, timestamp.isFinite else { return trackedProgress }
        return spring.value(at: timestamp).clamped(to: Self.progressBounds)
    }

    func velocity(at timestamp: TimeInterval) -> Double {
        guard let spring, timestamp.isFinite else { return tracker.velocity() }
        let value = spring.value(at: timestamp)
        guard Self.progressBounds.contains(value) else { return 0 }
        return spring.velocity(at: timestamp)
    }

    func isComplete(at timestamp: TimeInterval) -> Bool {
        timestamp.isFinite && (spring?.isComplete(at: timestamp) ?? false)
    }

    @discardableResult
    func update(cumulativeUnits: Double, timestamp: TimeInterval) -> Bool {
        guard spring == nil, accepts(cumulativeUnits: cumulativeUnits, timestamp: timestamp) else { return false }
        let raw = baselineProgress + (cumulativeUnits - originUnits) / Self.travelUnits
        guard raw.isFinite else { return false }
        let progress = Self.rubberBand(raw)
        guard tracker.push(delta: progress - trackedProgress, timestamp: timestamp) else { return false }
        trackedProgress = progress
        lastTimestamp = timestamp
        return true
    }

    @discardableResult
    func release(
        timestamp: TimeInterval,
        allowFlick: Bool,
        animationTime: TimeInterval,
        motion: MotionSnapshot = .enabled
    ) -> Bool {
        guard spring == nil, timestamp.isFinite, timestamp >= lastTimestamp,
              animationTime.isFinite else { return false }
        tracker.push(delta: 0, timestamp: timestamp)
        let velocity = allowFlick ? tracker.velocity() : 0
        let projected = trackedProgress - velocity / Self.projectionDecay
        let destination = allowFlick && projected >= 0.5 ? 1.0 : 0.0
        TrackpadScrollTrace.record(.workspacePresentation(
            renderer: "preview", action: "released", progress: trackedProgress, velocity: velocity,
            projectedProgress: projected, target: destination, allowFlick: allowFlick
        ))
        target = destination
        lastTimestamp = timestamp
        spring = SpringAnimation(
            from: trackedProgress,
            to: destination,
            initialVelocity: velocity,
            startTime: animationTime,
            config: motion.scaled(Self.springConfig)
        )
        return true
    }

    @discardableResult
    func animateToDestination(startTime: TimeInterval, motion: MotionSnapshot) -> Bool {
        guard spring == nil, target == nil, startTime.isFinite else { return false }
        target = 1
        spring = SpringAnimation(
            from: trackedProgress,
            to: 1,
            startTime: startTime,
            config: motion.scaled(Self.springConfig)
        )
        return true
    }

    @discardableResult
    func catchMotion(cumulativeUnits: Double, timestamp: TimeInterval, animationTime: TimeInterval) -> Bool {
        guard accepts(cumulativeUnits: cumulativeUnits, timestamp: timestamp),
              animationTime.isFinite else { return false }
        trackedProgress = progress(at: animationTime)
        baselineProgress = Self.rubberBandInverse(trackedProgress)
        originUnits = cumulativeUnits
        lastTimestamp = timestamp
        spring = nil
        target = nil
        tracker.reset()
        tracker.push(delta: 0, timestamp: timestamp)
        return true
    }

    private func accepts(cumulativeUnits: Double, timestamp: TimeInterval) -> Bool {
        cumulativeUnits.isFinite && timestamp.isFinite && timestamp >= lastTimestamp
    }

    private static func rubberBand(_ raw: Double) -> Double {
        if raw < 0 { return -resist(-raw) }
        if raw > 1 { return 1 + resist(raw - 1) }
        return raw
    }

    private static func rubberBandInverse(_ progress: Double) -> Double {
        if progress < 0 { return -unresist(-progress) }
        if progress > 1 { return 1 + unresist(progress - 1) }
        return progress
    }

    private static func resist(_ excess: Double) -> Double {
        stretch / (1 + stretch / (resistance * excess))
    }

    private static func unresist(_ excess: Double) -> Double {
        let bounded = min(excess, stretch - 1e-9)
        return bounded * stretch / (resistance * (stretch - bounded))
    }
}
