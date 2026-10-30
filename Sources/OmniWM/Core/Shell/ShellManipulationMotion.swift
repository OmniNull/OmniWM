// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

struct ShellWrapperMotion: Equatable, Sendable {
    struct Channel: Equatable, Sendable {
        let from: Double
        let to: Double
        let velocity: Double
        let begin: CFTimeInterval
        let spring: ShellSpringDynamics.Parameters
        let duration: CFTimeInterval
    }

    let x: Channel
    let y: Channel
    let scale: Channel

    func progress(in layout: CGRect, canvas: CGRect, source: ShellMorphRecipe.Source) -> ShellReveal {
        let offset: Double
        let horizontal: Double
        let vertical: Double
        let size: Double
        switch source.edge {
        case .top:
            (offset, horizontal, vertical, size) = (layout.minY - canvas.minY, 0, 1, 0)
        case .left:
            (offset, horizontal, vertical, size) = (layout.minX - canvas.minX, 1, 0, 0)
        case .right:
            (offset, horizontal, vertical, size) = (canvas.maxX - layout.minX, -1, 0, -layout.width)
        case .bottom:
            (offset, horizontal, vertical, size) = (canvas.maxY - layout.minY, 0, -1, -layout.height)
        }
        func projected(_ x: Double, _ y: Double, _ scale: Double) -> Double {
            (offset - source.from + horizontal * x + vertical * y + size * scale) / source.span
        }
        return ShellReveal(
            begin: x.begin,
            progress: projected(x.from, y.from, scale.from),
            velocity: (horizontal * x.velocity + vertical * y.velocity + size * scale.velocity) / source.span,
            target: projected(x.to, y.to, scale.to),
            spring: x.spring,
            duration: x.duration
        )
    }
}

struct ShellManipulationClip: Sendable {
    static let standardOutline = CGColor(gray: 1, alpha: 0.7)

    let size: CGSize
    let outline: CGColor?
}

enum ShellManipulationPresentation: Sendable {
    static let identity = ShellManipulationPresentation.still(translation: .zero, scale: 1, clip: nil)

    case still(translation: CGPoint, scale: CGFloat, clip: ShellManipulationClip?)
    case motion(ShellWrapperMotion)
}

struct ShellManipulationMotion: Sendable {
    struct Velocity: Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double

        static let zero = Velocity(x: 0, y: 0, width: 0)
    }

    private static let residualLimit = 0.25
    private static let speedLimit = 1.0

    let start: CGRect
    let target: CGRect
    let startVelocity: Velocity
    let begin: CFTimeInterval
    let spring: ShellSpringDynamics.Parameters
    let duration: CFTimeInterval
    let trajectoryBounds: CGRect

    private var aspect: Double {
        target.height / target.width
    }

    init?(
        from start: CGRect,
        velocity: Velocity = .zero,
        to target: CGRect,
        begin: CFTimeInterval,
        spring: ShellSpringDynamics.Parameters
    ) {
        guard ShellManipulationGeometry.valid(start), ShellManipulationGeometry.valid(target),
              velocity.x.isFinite, velocity.y.isFinite, velocity.width.isFinite, begin.isFinite,
              Self.positive(spring.mass), Self.positive(spring.stiffness), Self.positive(spring.damping)
        else { return nil }
        let aspect = target.height / target.width
        let displacements = SIMD4(
            start.minX - target.minX,
            start.minY - target.minY,
            start.width - target.width,
            (start.width - target.width) * aspect
        )
        let velocities = SIMD4(velocity.x, velocity.y, velocity.width, velocity.width * aspect)
        let x = ShellSpringDynamics.range(
            displacement: displacements[0], initialVelocity: velocities[0], spring: spring
        )
        let y = ShellSpringDynamics.range(
            displacement: displacements[1], initialVelocity: velocities[1], spring: spring
        )
        let width = ShellSpringDynamics.range(
            displacement: displacements[2], initialVelocity: velocities[2], spring: spring
        )
        self.start = CGRect(origin: start.origin, size: CGSize(width: start.width, height: start.width * aspect))
        self.target = target
        startVelocity = velocity
        self.begin = begin
        self.spring = spring
        duration = ShellSpringDynamics.settleTime(
            displacement: displacements, velocity: velocities, spring: spring,
            residual: Self.residualLimit, speed: Self.speedLimit
        )
        trajectoryBounds = CGRect(
            x: target.minX + x.lowerBound,
            y: target.minY + y.lowerBound,
            width: x.upperBound - x.lowerBound + target.width + width.upperBound,
            height: y.upperBound - y.lowerBound + (target.width + width.upperBound) * aspect
        )
    }

    func rect(at time: CFTimeInterval) -> CGRect {
        let elapsed = max(0, time - begin)
        let width = target.width + offset(start.width - target.width, startVelocity.width, elapsed)
        return CGRect(
            x: target.minX + offset(start.minX - target.minX, startVelocity.x, elapsed),
            y: target.minY + offset(start.minY - target.minY, startVelocity.y, elapsed),
            width: width,
            height: width * aspect
        )
    }

    func velocity(at time: CFTimeInterval) -> Velocity {
        let elapsed = max(0, time - begin)
        return Velocity(
            x: speed(start.minX - target.minX, startVelocity.x, elapsed),
            y: speed(start.minY - target.minY, startVelocity.y, elapsed),
            width: speed(start.width - target.width, startVelocity.width, elapsed)
        )
    }

    func retargeted(at time: CFTimeInterval, to destination: CGRect) -> ShellManipulationMotion? {
        ShellManipulationMotion(
            from: rect(at: time),
            velocity: velocity(at: time),
            to: destination,
            begin: time,
            spring: spring
        )
    }

    func settled(at time: CFTimeInterval) -> Bool {
        time >= begin + duration
    }

    func wrapper(for layout: CGRect) -> ShellWrapperMotion {
        ShellWrapperMotion(
            x: channel(start.minX - layout.minX, target.minX - layout.minX, startVelocity.x),
            y: channel(start.minY - layout.minY, target.minY - layout.minY, startVelocity.y),
            scale: channel(start.width / layout.width, target.width / layout.width, startVelocity.width / layout.width)
        )
    }

    private func offset(_ displacement: Double, _ velocity: Double, _ elapsed: Double) -> Double {
        ShellSpringDynamics.position(
            at: elapsed, displacement: displacement, initialVelocity: velocity, spring: spring
        )
    }

    private func speed(_ displacement: Double, _ velocity: Double, _ elapsed: Double) -> Double {
        ShellSpringDynamics.velocity(
            at: elapsed, displacement: displacement, initialVelocity: velocity, spring: spring
        )
    }

    private func channel(_ from: Double, _ to: Double, _ velocity: Double) -> ShellWrapperMotion.Channel {
        ShellWrapperMotion.Channel(
            from: from, to: to, velocity: velocity, begin: begin, spring: spring, duration: duration
        )
    }

    private static func positive(_ value: Double) -> Bool {
        value.isFinite && value > 0
    }
}
