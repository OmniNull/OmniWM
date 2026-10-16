// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum ShellSpringDynamics {
    struct Parameters {
        let mass: Double
        let stiffness: Double
        let damping: Double
    }

    static func velocity(
        at elapsed: Double,
        displacement: Double,
        initialVelocity: Double,
        spring: Parameters
    ) -> Double {
        let mass = spring.mass
        let stiffness = spring.stiffness
        let damping = spring.damping
        guard elapsed.isFinite, elapsed >= 0, displacement.isFinite, initialVelocity.isFinite,
              mass.isFinite, mass > 0, stiffness.isFinite, stiffness > 0,
              damping.isFinite, damping >= 0
        else { return 0 }
        if elapsed == 0 { return initialVelocity }
        let frequencySquared = stiffness / mass
        let decay = damping / mass / 2
        guard frequencySquared.isFinite, frequencySquared > 0, decay.isFinite else { return 0 }
        let frequency = sqrt(frequencySquared)
        let velocity: Double
        if decay == frequency {
            velocity = exp(-decay * elapsed)
                * (initialVelocity - (decay * initialVelocity + frequencySquared * displacement) * elapsed)
        } else if decay < frequency {
            let oscillation = sqrt((frequency - decay) * (frequency + decay))
            let phase = oscillation * elapsed
            velocity = exp(-decay * elapsed)
                * (initialVelocity * cos(phase)
                    - (decay * initialVelocity + frequencySquared * displacement) * sin(phase) / oscillation)
        } else {
            let separation = sqrt((decay - frequency) * (decay + frequency))
            let fast = -decay - separation
            let slow = frequencySquared / fast
            let interval = 2 * separation
            let relative = expm1(-interval * elapsed) / interval
            velocity = exp(slow * elapsed)
                * (initialVelocity + (fast * relative) * (slow * displacement - initialVelocity))
        }
        return velocity.isFinite ? velocity : 0
    }
}
