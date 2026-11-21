// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

struct OverviewNativeTransition {
    static let response = 0.25
    static let closeHandoffProgress = 0.01
    static let closeRevealProgress = 0.08
    static let settleTimeResolution: CFTimeInterval = 0.001
    private static let rubberBandCoefficient = 0.55
    private static let rubberBandDimension = 0.30
    private static let flickVelocity = 0.5
    private static let inertia = 0.15
    private static let responseCompression = 0.25

    let generation: UInt64
    let startTime: CFTimeInterval
    let from: Double
    let target: Double
    let initialVelocity: Double
    let response: Double
    let duration: CFTimeInterval
    private let spring: CriticalSpring

    var chromeExitResponse: Double? {
        target == 0 ? response / 2 : nil
    }

    private var normalizedVelocity: Double {
        target == from ? 0 : initialVelocity / (target - from)
    }

    init(
        generation: UInt64,
        startTime: CFTimeInterval,
        from: Double,
        to: Double,
        initialVelocity: Double = 0,
        response: Double = Self.response
    ) {
        self.generation = generation
        self.startTime = startTime
        self.from = from
        target = to
        self.initialVelocity = initialVelocity
        self.response = response
        let frequency = 2 * .pi / response
        spring = CriticalSpring(displacement: from - to, initialVelocity: initialVelocity, frequency: frequency)
        let normalizedVelocity = to == from ? 0 : initialVelocity / (to - from)
        let settlingDuration = to == from
            ? 0
            : Self.makeSpring(initialVelocity: normalizedVelocity, frequency: frequency).settlingDuration
        duration = to == 0
            ? spring.settleTime(within: Self.closeHandoffProgress, latest: settlingDuration)
            : settlingDuration
    }

    func value(at time: CFTimeInterval) -> Double {
        let elapsed = max(0, time - startTime)
        guard elapsed < duration else { return target }
        return target + spring.offset(at: elapsed)
    }

    func velocity(at time: CFTimeInterval) -> Double {
        let elapsed = max(0, time - startTime)
        guard elapsed < duration else { return 0 }
        return spring.velocity(at: elapsed)
    }

    func makeAnimation(keyPath: String, response: Double? = nil) -> CASpringAnimation {
        let animation = Self.makeSpring(
            initialVelocity: normalizedVelocity,
            frequency: response.map { 2 * .pi / $0 } ?? spring.frequency
        )
        animation.keyPath = keyPath
        animation.beginTime = startTime
        animation.duration = response == nil ? duration : animation.settlingDuration
        return animation
    }

    func makeCloseReveal() -> CAKeyframeAnimation? {
        guard target == 0, duration > 0 else { return nil }
        let revealStart = spring.settleTime(within: Self.closeRevealProgress, latest: duration)
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [Float(1), 1, 0]
        animation.keyTimes = [0, NSNumber(value: revealStart / duration), 1]
        animation.beginTime = startTime
        animation.duration = duration
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        return animation
    }

    static func rubberBand(_ raw: Double) -> Double {
        if raw < 0 { return -resist(-raw) }
        if raw > 1 { return 1 + resist(raw - 1) }
        return raw
    }

    static func rubberBandInverse(_ progress: Double) -> Double {
        if progress < 0 { return -unresist(-progress) }
        if progress > 1 { return 1 + unresist(progress - 1) }
        return progress
    }

    static func releaseTarget(progress: Double, velocity: Double) -> Double {
        if progress > 1 { return 1 }
        if progress < 0 { return 0 }
        if velocity >= flickVelocity { return 1 }
        if velocity <= -flickVelocity { return 0 }
        return progress + velocity * inertia >= 0.5 ? 1 : 0
    }

    static func compressedResponse(forReleaseVelocity velocity: Double) -> Double {
        response * (1 - responseCompression * tanh(abs(velocity) / flickVelocity))
    }

    private static func resist(_ excess: Double) -> Double {
        excess * rubberBandDimension * rubberBandCoefficient
            / (rubberBandDimension + rubberBandCoefficient * excess)
    }

    private static func unresist(_ stretch: Double) -> Double {
        let bounded = min(stretch, rubberBandDimension - 1e-9)
        return bounded * rubberBandDimension / (rubberBandCoefficient * (rubberBandDimension - bounded))
    }

    private struct CriticalSpring {
        let displacement: Double
        let initialVelocity: Double
        let frequency: Double

        private var coefficient: Double {
            frequency * displacement + initialVelocity
        }

        func offset(at elapsed: CFTimeInterval) -> Double {
            exp(-frequency * elapsed) * (displacement + coefficient * elapsed)
        }

        func velocity(at elapsed: CFTimeInterval) -> Double {
            exp(-frequency * elapsed) * (initialVelocity - frequency * coefficient * elapsed)
        }

        func settleTime(within offsetLimit: Double, latest: CFTimeInterval) -> CFTimeInterval {
            var time = latest
            while time > 0, abs(offset(at: time)) <= offsetLimit {
                time -= OverviewNativeTransition.settleTimeResolution
            }
            return time <= 0 ? 0 : min(latest, time + OverviewNativeTransition.settleTimeResolution)
        }
    }

    private static func makeSpring(initialVelocity: Double, frequency: Double) -> CASpringAnimation {
        let animation = CASpringAnimation()
        animation.mass = 1
        animation.stiffness = frequency * frequency
        animation.damping = 2 * frequency
        animation.initialVelocity = initialVelocity
        return animation
    }
}
