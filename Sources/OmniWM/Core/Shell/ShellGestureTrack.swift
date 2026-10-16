// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import OmniWMShellCore

struct ShellGestureTransform: Equatable, Sendable {
    var dx: Double = 0
    var dy: Double = 0
    var scale: Double = 1
    var opacity: Double = 1

    static let identity = ShellGestureTransform()
    static let zero = ShellGestureTransform(scale: 0, opacity: 0)
}

struct ShellGestureTrack: Sendable {
    struct Channel: Sendable {
        let from: Double
        let to: Double
        let rubber: Double

        func sample(_ progress: Double, velocity: Double) -> (value: Double, velocity: Double) {
            let mapped: Double
            let derivative: Double
            if progress < 0 || progress > 1 {
                let boundary = progress < 0 ? 0.0 : 1.0
                let excess = progress - boundary
                let denominator = 1 + abs(excess)
                mapped = boundary + rubber * excess / denominator
                derivative = rubber / (denominator * denominator)
            } else {
                mapped = progress
                derivative = 1
            }
            let difference = to - from
            return (from + difference * mapped, difference * derivative * velocity)
        }
    }

    struct Sample: Sendable {
        let value: ShellGestureTransform
        let velocity: ShellGestureTransform
    }

    let dx: Channel
    let dy: Channel
    let scale: Channel
    let opacity: Channel

    init?(_ recipe: String) {
        guard recipe.utf8.count <= 384 else { return nil }
        let fields = recipe.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 14, fields[0] == "track", let mask = UInt8(fields[1]),
              (1 ... 15).contains(mask) else { return nil }
        var values: [Double] = []
        values.reserveCapacity(12)
        for field in fields.dropFirst(2) {
            guard let value = Double(field), value.isFinite else { return nil }
            values.append(value)
        }
        for index in 0 ..< 4 {
            let offset = index * 3
            let range = index < 2 ? -1_000_000.0 ... 1_000_000.0 : index == 2 ? 0.0 ... 1_000_000.0 : 0.0 ... 1.0
            guard range.contains(values[offset]), range.contains(values[offset + 1]),
                  (0 ... 1).contains(values[offset + 2]) else { return nil }
            if mask & (1 << index) == 0 {
                let identity = index < 2 ? 0.0 : 1.0
                guard values[offset] == identity, values[offset + 1] == identity,
                      values[offset + 2] == 0 else { return nil }
            }
        }
        dx = Channel(from: values[0], to: values[1], rubber: values[2])
        dy = Channel(from: values[3], to: values[4], rubber: values[5])
        scale = Channel(from: values[6], to: values[7], rubber: values[8])
        opacity = Channel(from: values[9], to: values[10], rubber: values[11])
    }

    func sample(
        translation: CGPoint,
        velocity: CGPoint,
        axis: ShellGestureConfig.Axis,
        configuration: ShellGestureConfig
    ) -> Sample {
        let normalized = Self.progress(
            translation: translation,
            velocity: velocity,
            axis: axis,
            configuration: configuration
        )
        let x = dx.sample(normalized.value, velocity: normalized.velocity)
        let y = dy.sample(normalized.value, velocity: normalized.velocity)
        let size = scale.sample(normalized.value, velocity: normalized.velocity)
        let alpha = opacity.sample(normalized.value, velocity: normalized.velocity)
        return Sample(
            value: ShellGestureTransform(
                dx: x.value,
                dy: y.value,
                scale: max(0, size.value),
                opacity: min(1, max(0, alpha.value))
            ),
            velocity: ShellGestureTransform(
                dx: x.velocity,
                dy: y.velocity,
                scale: size.value < 0 ? 0 : size.velocity,
                opacity: alpha.value < 0 || alpha.value > 1 ? 0 : alpha.velocity
            )
        )
    }

    static func progress(
        translation: CGPoint,
        velocity: CGPoint,
        axis: ShellGestureConfig.Axis,
        configuration: ShellGestureConfig
    ) -> (value: Double, velocity: Double) {
        let distance = Double(configuration.commitDistance)
        guard distance > 0 else { return (0, 0) }
        let x = Double(translation.x)
        let y = Double(translation.y)
        let vx = Double(velocity.x)
        let vy = Double(velocity.y)
        let displacement: Double
        let speed: Double
        switch configuration.direction {
        case .left: (displacement, speed) = (-x, -vx)
        case .right: (displacement, speed) = (x, vx)
        case .up: (displacement, speed) = (-y, -vy)
        case .down: (displacement, speed) = (y, vy)
        case .any:
            switch axis {
            case .x: (displacement, speed) = (abs(x), x == 0 ? 0 : (x > 0 ? vx : -vx))
            case .y: (displacement, speed) = (abs(y), y == 0 ? 0 : (y > 0 ? vy : -vy))
            case .free:
                displacement = hypot(x, y)
                speed = displacement > 0 ? (x * vx + y * vy) / displacement : 0
            case .none,
                 .auto: return (0, 0)
            }
        }
        return (displacement / distance, speed / distance)
    }
}
