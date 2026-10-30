// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import QuartzCore

enum ShellSpringDynamics {
    struct Parameters: Equatable {
        let mass: Double
        let stiffness: Double
        let damping: Double
    }

    static func position(
        at elapsed: Double,
        displacement: Double,
        initialVelocity: Double,
        spring: Parameters
    ) -> Double {
        state(at: elapsed, displacement: displacement, initialVelocity: initialVelocity, spring: spring).position
    }

    static func velocity(
        at elapsed: Double,
        displacement: Double,
        initialVelocity: Double,
        spring: Parameters
    ) -> Double {
        state(at: elapsed, displacement: displacement, initialVelocity: initialVelocity, spring: spring).velocity
    }

    static func range(displacement: Double, initialVelocity: Double, spring: Parameters) -> ClosedRange<Double> {
        let frequencySquared = spring.stiffness / spring.mass
        let decay = spring.damping / spring.mass / 2
        let frequency = sqrt(frequencySquared)
        let restoring = decay * initialVelocity + frequencySquared * displacement
        let turns: (Double, Double)
        if decay == frequency {
            turns = (initialVelocity / restoring, 0)
        } else if decay < frequency {
            let oscillation = sqrt((frequency - decay) * (frequency + decay))
            let phase = atan2(initialVelocity * oscillation, restoring)
            let first = phase < 0 ? phase + .pi : phase
            turns = (first / oscillation, (first + .pi) / oscillation)
        } else {
            let separation = sqrt((decay - frequency) * (decay + frequency))
            let fast = -decay - separation
            let slow = frequencySquared / fast
            let interval = 2 * separation
            let decayed = -initialVelocity * interval / (fast * (slow * displacement - initialVelocity))
            turns = (-log1p(decayed) / interval, 0)
        }
        let first = position(at: turns.0, displacement: displacement, initialVelocity: initialVelocity, spring: spring)
        let second = position(at: turns.1, displacement: displacement, initialVelocity: initialVelocity, spring: spring)
        return min(min(0, displacement), min(first, second)) ... max(max(0, displacement), max(first, second))
    }

    static func settleTime(
        displacement: SIMD4<Double>,
        velocity: SIMD4<Double>,
        spring: Parameters,
        residual: Double,
        speed speedLimit: Double
    ) -> Double {
        let decay = spring.damping / spring.mass / 2
        let frequencySquared = spring.stiffness / spring.mass
        let rate = decay * decay > frequencySquared
            ? frequencySquared / (decay + sqrt(decay * decay - frequencySquared))
            : decay
        let reach = 2 / (exp(1) * rate)
        let drift = velocity + decay * displacement
        let restoring = decay * velocity + frequencySquared * displacement
        var excess = 1.0
        for lane in displacement.indices {
            excess = max(
                excess,
                max(
                    (abs(displacement[lane]) + reach * abs(drift[lane])) / residual,
                    (abs(velocity[lane]) + reach * abs(restoring[lane])) / speedLimit
                )
            )
        }
        let limit = 2 * log(excess) / rate
        guard limit > 0 else { return 0 }
        let samples = 512
        let step = limit / Double(samples)
        let carried = position(at: step, displacement: 1, initialVelocity: 0, spring: spring)
        let launched = position(at: step, displacement: 0, initialVelocity: 1, spring: spring)
        let restored = self.velocity(at: step, displacement: 1, initialVelocity: 0, spring: spring)
        let damped = self.velocity(at: step, displacement: 0, initialVelocity: 1, spring: spring)
        var offset = displacement
        var speed = velocity
        for sample in 1 ... samples {
            (offset, speed) = (carried * offset + launched * speed, restored * offset + damped * speed)
            if all(offset * offset .< residual * residual), all(speed * speed .< speedLimit * speedLimit) {
                return step * Double(sample)
            }
        }
        return limit
    }

    private static func state(
        at elapsed: Double,
        displacement: Double,
        initialVelocity: Double,
        spring: Parameters
    ) -> (position: Double, velocity: Double) {
        let mass = spring.mass
        let stiffness = spring.stiffness
        let damping = spring.damping
        guard elapsed.isFinite, elapsed >= 0, displacement.isFinite, initialVelocity.isFinite,
              mass.isFinite, mass > 0, stiffness.isFinite, stiffness > 0,
              damping.isFinite, damping >= 0
        else { return (0, 0) }
        if elapsed == 0 { return (displacement, initialVelocity) }
        let frequencySquared = stiffness / mass
        let decay = damping / mass / 2
        guard frequencySquared.isFinite, frequencySquared > 0, decay.isFinite else { return (0, 0) }
        let frequency = sqrt(frequencySquared)
        let drift = initialVelocity + decay * displacement
        let position: Double
        let velocity: Double
        if decay == frequency {
            let envelope = exp(-decay * elapsed)
            position = envelope * (displacement + drift * elapsed)
            velocity = envelope
                * (initialVelocity - (decay * initialVelocity + frequencySquared * displacement) * elapsed)
        } else if decay < frequency {
            let oscillation = sqrt((frequency - decay) * (frequency + decay))
            let phase = oscillation * elapsed
            let envelope = exp(-decay * elapsed)
            let cosine = cos(phase)
            let sine = sin(phase)
            position = envelope * (displacement * cosine + drift * sine / oscillation)
            velocity = envelope
                * (initialVelocity * cosine
                    - (decay * initialVelocity + frequencySquared * displacement) * sine / oscillation)
        } else {
            let separation = sqrt((decay - frequency) * (decay + frequency))
            let fast = -decay - separation
            let slow = frequencySquared / fast
            let interval = 2 * separation
            let relative = expm1(-interval * elapsed) / interval
            let envelope = exp(slow * elapsed)
            position = envelope * (displacement + relative * (slow * displacement - initialVelocity))
            velocity = envelope
                * (initialVelocity + (fast * relative) * (slow * displacement - initialVelocity))
        }
        return (position.isFinite ? position : 0, velocity.isFinite ? velocity : 0)
    }
}

extension ShellSpringDynamics.Parameters {
    init?(_ animation: ShellAnimation) {
        guard let spring = animation.make("transform") as? CASpringAnimation else { return nil }
        self.init(mass: spring.mass, stiffness: spring.stiffness, damping: spring.damping)
    }
}
