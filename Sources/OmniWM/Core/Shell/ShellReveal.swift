// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

struct ShellReveal: Equatable, Sendable {
    struct Sample {
        let time: CFTimeInterval
        let progress: Double
        let velocity: Double
    }

    static let rate = 120.0
    private static let residualLimit = 0.002
    private static let speedLimit = 0.02

    let begin: CFTimeInterval
    let commit: CFTimeInterval
    let progress: Double
    let velocity: Double
    let target: Double
    let spring: ShellSpringDynamics.Parameters
    let duration: CFTimeInterval
    let contact: ShellShapeContact?

    init(
        begin: CFTimeInterval,
        commit: CFTimeInterval? = nil,
        progress: Double,
        velocity: Double = 0,
        target: Double,
        spring: ShellSpringDynamics.Parameters,
        duration: CFTimeInterval? = nil,
        contact: ShellShapeContact? = nil
    ) {
        self.contact = contact
        self.begin = begin
        self.commit = commit ?? begin
        self.progress = progress
        self.velocity = velocity
        self.target = target
        self.spring = spring
        self.duration = duration ?? ShellSpringDynamics.settleTime(
            displacement: SIMD4(progress - target, 0, 0, 0),
            velocity: SIMD4(velocity, 0, 0, 0),
            spring: spring,
            residual: Self.residualLimit,
            speed: Self.speedLimit
        )
    }

    var end: CFTimeInterval {
        begin + duration
    }

    func state(at time: CFTimeInterval) -> (progress: Double, velocity: Double) {
        let elapsed = max(0, time - begin)
        guard elapsed < duration else { return (target, 0) }
        let displacement = progress - target
        return (
            target + ShellSpringDynamics.position(
                at: elapsed, displacement: displacement, initialVelocity: velocity, spring: spring
            ),
            ShellSpringDynamics.velocity(
                at: elapsed, displacement: displacement, initialVelocity: velocity, spring: spring
            )
        )
    }

    func retargeted(at time: CFTimeInterval, to target: Double) -> ShellReveal {
        let state = state(at: time)
        return ShellReveal(
            begin: max(begin, time), commit: time, progress: state.progress, velocity: state.velocity,
            target: target, spring: spring, contact: contact
        )
    }

    var samples: [Sample] {
        let count = Int((duration * Self.rate).rounded(.up))
        var samples: [Sample] = []
        samples.reserveCapacity(count + 1)
        for index in 0 ..< count {
            let time = Double(index) / Self.rate
            let state = state(at: begin + time)
            samples.append(Sample(time: time, progress: state.progress, velocity: state.velocity))
        }
        samples.append(Sample(time: duration, progress: target, velocity: 0))
        return samples
    }
}

extension ShellMorphRecipe {
    func stop(at progress: Double) -> Stop {
        var lower = stops[0]
        guard progress > lower.at else { return lower }
        for upper in stops.dropFirst() {
            guard progress < upper.at else {
                lower = upper
                continue
            }
            let fraction = (progress - lower.at) / (upper.at - lower.at)
            func mix(_ from: Double, _ to: Double) -> Double {
                from + (to - from) * fraction
            }
            return Stop(
                at: progress,
                scale: mix(lower.scale, upper.scale),
                opacity: mix(lower.opacity, upper.opacity),
                width: mix(lower.width, upper.width),
                height: mix(lower.height, upper.height),
                round: mix(lower.round, upper.round),
                dx: mix(lower.dx, upper.dx),
                dy: mix(lower.dy, upper.dy),
                thickness: mix(lower.thickness, upper.thickness)
            )
        }
        return lower
    }

    func stretching(at velocity: Double) -> Double {
        min(max(stretch.gain * velocity, 0), stretch.max)
    }

    func scaled(_ rect: CGRect, by scale: Double) -> CGRect {
        let pivot = CGPoint(x: rect.minX + rect.width * anchor.x, y: rect.minY + rect.height * anchor.y)
        return CGRect(
            x: pivot.x + (rect.minX - pivot.x) * scale,
            y: pivot.y + (rect.minY - pivot.y) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    func shape(
        _ rect: CGRect,
        radius: CGFloat,
        progress: Double,
        velocity: Double
    ) -> (rect: CGRect, radius: CGFloat) {
        let stop = stop(at: progress)
        let base = scaled(rect, by: stop.scale)
        let sigma = stretching(at: velocity)
        let width = max(0, base.width * (stop.width + stretch.width * sigma))
        let height = max(0, base.height * (stop.height + stretch.height * sigma))
        let capsule = min(base.width, base.height) / 2
        return (
            CGRect(
                x: base.midX - width / 2 + stop.dx,
                y: base.midY - height / 2 + stop.dy,
                width: width,
                height: height
            ),
            max(0, min(capsule + (radius - capsule) * stop.round, min(width, height) / 2))
        )
    }
}

extension ShellReveal {
    func crossings(at threshold: Double, rising: Bool) -> [CFTimeInterval] {
        guard duration > 0, threshold.isFinite else { return [] }
        let boundaries = crossingBoundaries()
        var result: [CFTimeInterval] = []
        for index in 1 ..< boundaries.count {
            guard let crossing = crossing(
                from: boundaries[index - 1], to: boundaries[index], at: threshold, rising: rising
            ) else { continue }
            if result.last.map({ abs($0 - crossing) > 1e-9 }) ?? true { result.append(crossing) }
        }
        return result
    }

    private func crossingBoundaries() -> [Double] {
        let frequencySquared = spring.stiffness / spring.mass
        let frequency = sqrt(frequencySquared)
        let decay = spring.damping / spring.mass / 2
        let offset = progress - target
        let restoring = decay * velocity + frequencySquared * offset
        var boundaries = [0.0]
        if decay < frequency {
            let oscillation = sqrt((frequency - decay) * (frequency + decay))
            let step = Double.pi / oscillation
            var turn = atan2(velocity * oscillation, restoring) / oscillation
            turn += max(0, floor(-turn / step) + 1) * step
            while turn < duration {
                if turn > 0 { boundaries.append(turn) }
                turn += step
            }
        } else if decay == frequency {
            let turn = velocity / restoring
            if turn.isFinite, turn > 0, turn < duration { boundaries.append(turn) }
        } else {
            let separation = sqrt((decay - frequency) * (decay + frequency))
            let fast = -decay - separation
            let slow = frequencySquared / fast
            let slowAmplitude = (velocity - fast * offset) / (slow - fast)
            let fastAmplitude = offset - slowAmplitude
            let ratio = -(fastAmplitude * fast) / (slowAmplitude * slow)
            let turn = log(ratio) / (slow - fast)
            if turn.isFinite, turn > 0, turn < duration { boundaries.append(turn) }
        }
        boundaries.append(duration)
        return boundaries
    }

    private func crossing(from start: Double, to end: Double, at threshold: Double, rising: Bool) -> CFTimeInterval? {
        func value(_ elapsed: Double) -> Double {
            target + ShellSpringDynamics.position(
                at: elapsed, displacement: progress - target, initialVelocity: velocity, spring: spring
            ) - threshold
        }
        var low = start, high = end
        let left = value(low), right = value(high)
        let ascending = right > left
        guard ascending == rising, left != right, left * right <= 0 else { return nil }
        if left == 0 { return begin + low }
        for _ in 0 ..< 48 {
            let middle = (low + high) / 2
            if (value(middle) > 0) == ascending { high = middle } else { low = middle }
        }
        return begin + (low + high) / 2
    }
}
