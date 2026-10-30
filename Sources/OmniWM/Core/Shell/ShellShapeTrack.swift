// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

extension ShellMorphRecipe.Spring {
    var parameters: ShellSpringDynamics.Parameters {
        let frequency = 2 * Double.pi / response
        return ShellSpringDynamics.Parameters(
            mass: 1,
            stiffness: frequency * frequency,
            damping: 2 * (1 - bounce) * frequency
        )
    }
}

extension ShellMorphRecipe {
    func shape(_ base: ShellGlassShape, progress: Double, velocity: Double) -> ShellGlassShape {
        let geometry = shape(base.rect, radius: base.radius, progress: progress, velocity: velocity)
        let stop = stop(at: progress)
        return ShellGlassShape(
            slot: base.slot, kind: base.kind, rect: geometry.rect, radius: geometry.radius,
            thickness: max(0, base.thickness * stop.scale * stop.thickness), rotation: base.rotation
        )
    }
}

struct ShellShapeImpulse: Sendable {
    let begin: CFTimeInterval
    let spring: ShellSpringDynamics.Parameters
    let displacement: Double
    let velocity: Double
    let width: Double
    let height: Double
    let pivot: ShellMorphRecipe.ImpulsePivot
    let duration: CFTimeInterval

    init(_ recipe: ShellMorphRecipe.Impulse, begin: CFTimeInterval) {
        self.init(
            begin: begin, spring: recipe.spring.parameters, displacement: 0, velocity: recipe.velocity,
            width: recipe.width, height: recipe.height, pivot: recipe.pivot
        )
    }

    private init(
        begin: CFTimeInterval, spring: ShellSpringDynamics.Parameters, displacement: Double,
        velocity: Double, width: Double, height: Double, pivot: ShellMorphRecipe.ImpulsePivot
    ) {
        self.begin = begin
        self.spring = spring
        self.displacement = displacement
        self.velocity = velocity
        self.width = width
        self.height = height
        self.pivot = pivot
        duration = ShellSpringDynamics.settleTime(
            displacement: SIMD4(displacement * width, displacement * height, 0, 0),
            velocity: SIMD4(velocity * width, velocity * height, 0, 0), spring: spring,
            residual: 0.002, speed: 0.02
        )
    }

    var end: CFTimeInterval {
        begin + duration
    }

    static func scheduled(
        _ recipes: [ShellMorphRecipe.Impulse], on plan: ShellReveal, commit: CFTimeInterval
    ) -> [ShellShapeImpulse] {
        recipes.flatMap { recipe -> [ShellShapeImpulse] in
            guard recipe.phase == .both || (recipe.phase == .open && plan.target == 1)
                || (recipe.phase == .close && plan.target == 0) else { return [] }
            let times = recipe.kind == .after ? [commit + recipe.time] : plan.crossings(
                at: recipe.time,
                rising: recipe.rising
            )
            return times.map { ShellShapeImpulse(recipe, begin: $0) }
        }.sorted { $0.begin < $1.begin }
    }

    func state(at time: CFTimeInterval) -> (displacement: Double, velocity: Double) {
        guard time >= begin else { return (0, 0) }
        guard time < end else { return (0, 0) }
        return (
            ShellSpringDynamics.position(
                at: time - begin,
                displacement: displacement,
                initialVelocity: velocity,
                spring: spring
            ),
            ShellSpringDynamics.velocity(
                at: time - begin,
                displacement: displacement,
                initialVelocity: velocity,
                spring: spring
            )
        )
    }

    func carrying(at time: CFTimeInterval) -> ShellShapeImpulse? {
        guard time >= begin, time < end else { return nil }
        let state = state(at: time)
        return ShellShapeImpulse(
            begin: time, spring: spring, displacement: state.displacement, velocity: state.velocity,
            width: width, height: height, pivot: pivot
        )
    }

    func apply(to shape: ShellGlassShape, anchor: CGPoint, at time: CFTimeInterval) -> ShellGlassShape {
        let delta = state(at: time).displacement
        let width = max(0, shape.rect.width + delta * self.width)
        let height = max(0, shape.rect.height + delta * self.height)
        let pivot = self.pivot == .centre ? CGPoint(x: 0.5, y: 0.5) : anchor
        let rect = CGRect(
            x: shape.rect.minX - (width - shape.rect.width) * pivot.x,
            y: shape.rect.minY - (height - shape.rect.height) * pivot.y,
            width: width, height: height
        )
        return ShellGlassShape(
            slot: shape.slot, kind: shape.kind, rect: rect,
            radius: min(shape.radius, min(width, height) / 2), thickness: shape.thickness, rotation: shape.rotation
        )
    }
}

struct ShellShapeEdges: Sendable {
    struct Channel: Sendable {
        let from: Double
        let velocity: Double
        let to: Double
        let spring: ShellSpringDynamics.Parameters

        func state(at elapsed: Double) -> (value: Double, velocity: Double) {
            (
                to + ShellSpringDynamics.position(
                    at: max(0, elapsed),
                    displacement: from - to,
                    initialVelocity: velocity,
                    spring: spring
                ),
                ShellSpringDynamics.velocity(
                    at: max(0, elapsed),
                    displacement: from - to,
                    initialVelocity: velocity,
                    spring: spring
                )
            )
        }

        var duration: CFTimeInterval {
            ShellSpringDynamics.settleTime(
                displacement: SIMD4(from - to, 0, 0, 0), velocity: SIMD4(velocity, 0, 0, 0),
                spring: spring, residual: 0.002, speed: 0.02
            )
        }
    }

    let begin: CFTimeInterval
    let target: CGRect
    let recipe: ShellMorphRecipe.Edges
    let horizontal: Bool
    let forward: Bool
    let lead: Channel
    let trail: Channel
    let middle: Channel
    let thickness: Channel

    init(
        from: CGRect,
        to: CGRect,
        recipe: ShellMorphRecipe.Edges,
        begin: CFTimeInterval,
        velocity: SIMD4<Double> = .zero
    ) {
        self.begin = begin
        target = to
        self.recipe = recipe
        horizontal = to.width >= to.height
        forward = horizontal ? to.midX >= from.midX : to.midY >= from.midY
        let first = horizontal ? from.minX : from.minY
        let last = horizontal ? from.maxX : from.maxY
        let firstVelocity = horizontal ? velocity.x : velocity.y
        let lastVelocity = horizontal ? velocity.z : velocity.w
        let firstTarget = horizontal ? to.minX : to.minY
        let lastTarget = horizontal ? to.maxX : to.maxY
        lead = Channel(
            from: forward ? last : first, velocity: forward ? lastVelocity : firstVelocity,
            to: forward ? lastTarget : firstTarget, spring: recipe.lead.parameters
        )
        trail = Channel(
            from: forward ? first : last, velocity: forward ? firstVelocity : lastVelocity,
            to: forward ? firstTarget : lastTarget, spring: recipe.trail.parameters
        )
        middle = Channel(
            from: horizontal ? from.midY : from.midX,
            velocity: horizontal ? (velocity.y + velocity.w) / 2 : (velocity.x + velocity.z) / 2,
            to: horizontal ? to.midY : to.midX, spring: recipe.lead.parameters
        )
        let fromSpan = horizontal ? from.width : from.height
        let restSpan = horizontal ? to.width : to.height
        let excess = abs(fromSpan - restSpan) / recipe.unit
        let factor = 1 - recipe.thin * min(1, excess)
        let spanRate = horizontal ? velocity.z - velocity.x : velocity.w - velocity.y
        let factorRate = excess > 0 && excess < 1
            ? -recipe.thin / recipe.unit * (fromSpan > restSpan ? 1 : -1) * spanRate : 0
        let targetThickness = horizontal ? to.height : to.width
        thickness = Channel(
            from: (horizontal ? from.height : from.width) - targetThickness * factor,
            velocity: (horizontal ? velocity.w - velocity.y : velocity.z - velocity.x) - targetThickness * factorRate,
            to: 0, spring: recipe.lead.parameters
        )
    }

    var end: CFTimeInterval {
        begin + max(max(lead.duration, trail.duration), max(middle.duration, thickness.duration))
    }

    func state(at time: CFTimeInterval) -> (rect: CGRect, velocity: SIMD4<Double>) {
        guard time < end else { return (target, .zero) }
        let elapsed = max(0, time - begin)
        let head = lead.state(at: elapsed), tail = trail.state(at: elapsed)
        let first = forward ? tail : head, last = forward ? head : tail
        let cross = middle.state(at: elapsed), width = thickness.state(at: elapsed)
        let rawSpan = last.value - first.value
        let span = max(0, rawSpan)
        let spanRate = rawSpan > 0 ? last.velocity - first.velocity : 0
        let rest = horizontal ? target.width : target.height
        let excess = abs(span - rest) / recipe.unit
        let factor = 1 - recipe.thin * min(1, excess)
        let factorRate = excess > 0 && excess < 1
            ? -recipe.thin / recipe.unit * (span > rest ? 1 : -1) * spanRate : 0
        let targetThickness = horizontal ? target.height : target.width
        let crossSpan = max(0, targetThickness * factor + width.value)
        let crossRate = crossSpan > 0 ? targetThickness * factorRate + width.velocity : 0
        let crossLow = cross.value - crossSpan / 2
        let lowRate = cross.velocity - crossRate / 2
        let highRate = cross.velocity + crossRate / 2
        return horizontal
            ? (
                CGRect(x: first.value, y: crossLow, width: span, height: crossSpan),
                SIMD4(first.velocity, lowRate, last.velocity, highRate)
            )
            : (
                CGRect(x: crossLow, y: first.value, width: crossSpan, height: span),
                SIMD4(lowRate, first.velocity, highRate, last.velocity)
            )
    }

    func rect(at time: CFTimeInterval) -> CGRect {
        state(at: time).rect
    }

    func velocity(at time: CFTimeInterval) -> SIMD4<Double> {
        state(at: time).velocity
    }

    func retargeted(to target: CGRect, at time: CFTimeInterval) -> ShellShapeEdges {
        let presented = state(at: time)
        return ShellShapeEdges(
            from: presented.rect, to: target, recipe: recipe, begin: time, velocity: presented.velocity
        )
    }
}
