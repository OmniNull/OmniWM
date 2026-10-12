// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Observation

enum AnimationSpeed {
    static let range = 0.25 ... 4.0

    static func normalized(_ value: Double) -> Double {
        value.isFinite ? value.clamped(to: range) : 1
    }
}

struct MotionSnapshot: Equatable, Sendable {
    let animationsEnabled: Bool
    let animationSpeed: Double

    init(animationsEnabled: Bool, animationSpeed: Double = 1) {
        self.animationsEnabled = animationsEnabled
        self.animationSpeed = AnimationSpeed.normalized(animationSpeed)
    }

    static let enabled = MotionSnapshot(animationsEnabled: true)
    static let disabled = MotionSnapshot(animationsEnabled: false)

    func scaled(_ config: SpringConfig) -> SpringConfig {
        guard animationSpeed != 1 else { return config }
        return SpringConfig(
            dampingRatio: config.dampingRatio,
            stiffness: config.stiffness * animationSpeed * animationSpeed,
            epsilon: config.epsilon,
            velocityEpsilon: config.velocityEpsilon
        )
    }

    func scaled(_ config: CubicConfig) -> CubicConfig {
        guard animationSpeed != 1 else { return config }
        return CubicConfig(
            duration: config.duration / animationSpeed,
            controlPoint1: config.controlPoint1,
            controlPoint2: config.controlPoint2
        )
    }
}

@MainActor @Observable
final class MotionPolicy {
    var userAnimationsEnabled: Bool {
        didSet { if oldValue != userAnimationsEnabled { onAnimationsEnabledChange() } }
    }

    var systemReducesMotion = false {
        didSet { if oldValue != systemReducesMotion { onAnimationsEnabledChange() } }
    }

    @ObservationIgnored var onAnimationsEnabledChange: @MainActor () -> Void = {}
    var animationSpeed: Double {
        didSet {
            let normalized = AnimationSpeed.normalized(animationSpeed)
            if animationSpeed != normalized {
                animationSpeed = normalized
            }
        }
    }

    var animationsEnabled: Bool {
        get { userAnimationsEnabled && !systemReducesMotion }
        set { userAnimationsEnabled = newValue }
    }

    init(animationsEnabled: Bool = true, animationSpeed: Double = 1) {
        userAnimationsEnabled = animationsEnabled
        self.animationSpeed = AnimationSpeed.normalized(animationSpeed)
    }

    func snapshot() -> MotionSnapshot {
        MotionSnapshot(animationsEnabled: animationsEnabled, animationSpeed: animationSpeed)
    }
}
