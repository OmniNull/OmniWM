// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

struct ShellShapeBaseMotion {
    private(set) var target: ShellGlassShape
    let begin: CFTimeInterval
    let spring: ShellSpringDynamics.Parameters?
    let ease: ShellAnimation?
    let from: SIMD8<Double>
    let velocity: SIMD8<Double>
    let duration: CFTimeInterval

    init(
        from shape: ShellGlassShape, velocity: SIMD8<Double> = .zero, to target: ShellGlassShape,
        begin: CFTimeInterval, spring: ShellSpringDynamics.Parameters? = nil, ease: ShellAnimation? = nil
    ) {
        self.target = target
        self.begin = begin
        self.spring = spring
        if let ease, case .ease = ease.motion { self.ease = ease }
        else { self.ease = nil }
        from = Self.vector(shape)
        self.velocity = velocity
        if let ease = self.ease, case let .ease(seconds) = ease.motion {
            duration = seconds / ease.speed
        } else if let spring {
            let delta = from - Self.vector(target)
            duration = max(
                ShellSpringDynamics.settleTime(
                    displacement: SIMD4(delta[0], delta[1], delta[2], delta[3]),
                    velocity: SIMD4(velocity[0], velocity[1], velocity[2], velocity[3]),
                    spring: spring, residual: 0.002, speed: 0.02
                ),
                ShellSpringDynamics.settleTime(
                    displacement: SIMD4(delta[4], delta[5], delta[6], 0),
                    velocity: SIMD4(velocity[4], velocity[5], velocity[6], 0),
                    spring: spring, residual: 0.002, speed: 0.02
                )
            )
        } else { duration = 0 }
    }

    var end: CFTimeInterval {
        begin + duration
    }

    func state(at time: CFTimeInterval) -> (shape: ShellGlassShape, velocity: SIMD8<Double>) {
        guard time < end else { return (target, .zero) }
        let elapsed = max(0, time - begin)
        let to = Self.vector(target)
        var value = to
        var speed = SIMD8<Double>.zero
        if let ease, let curve = ease.curve ?? ShellCurve(wire: 4, custom: nil) {
            let state = curve.state(at: elapsed / duration)
            value = from + (to - from) * Double(state.value)
            speed = (to - from) * Double(state.velocity / duration)
        } else if let spring {
            for index in 0 ..< 7 {
                value[index] += ShellSpringDynamics.position(
                    at: elapsed, displacement: from[index] - to[index], initialVelocity: velocity[index], spring: spring
                )
                speed[index] = ShellSpringDynamics.velocity(
                    at: elapsed, displacement: from[index] - to[index], initialVelocity: velocity[index], spring: spring
                )
            }
        }
        return (
            ShellGlassShape(
                slot: target.slot, kind: target.kind,
                rect: CGRect(x: value[0], y: value[1], width: max(0, value[2]), height: max(0, value[3])),
                radius: max(0, value[4]), thickness: max(0, value[5]), rotation: value[6]
            ), speed
        )
    }

    func rekeyed(to slot: Int32) -> Self {
        var result = self
        result.target = target.with(slot: slot)
        return result
    }

    static func vector(_ shape: ShellGlassShape) -> SIMD8<Double> {
        SIMD8(
            shape.rect.minX, shape.rect.minY, shape.rect.width, shape.rect.height,
            shape.radius, shape.thickness, shape.rotation, 0
        )
    }
}

struct ShellShapeTrackEntry {
    let body: Int32
    let identity: ShellLayerIdentity?
    var base: ShellShapeBaseMotion
    var morph: ShellMorphRecipe
    var plan: ShellReveal?
    var bound: ShellBoundTrack?
    var triggerPlans: [ShellReveal] = []
    var triggerRevision: UInt64?
    var edges: ShellShapeEdges?
    var impulses: [ShellShapeImpulse] = []
    var begin: CFTimeInterval
    var generation: UInt64 = 0
    var root: Int32?
    var triggerBegin: CFTimeInterval?
    var carrier: CALayer?
    var dirty = true
    var animations: [ShellRevealAnimation] = []
    var union = CGRect.null

    var duration: CFTimeInterval {
        let motion = max(plan.map { $0.begin - begin + $0.duration } ?? 0, base.begin - begin + base.duration)
        let effects = max(
            edges.map { $0.end - begin } ?? 0,
            impulses.reduce(0) { max($0, $1.begin - begin + $1.duration) }
        )
        let source = carrier == nil ? max(bound.map {
            max($0.input.time - begin, $0.plan.begin - begin + $0.plan.duration)
        } ?? 0, triggerPlans.reduce(0) { max($0, $1.begin - begin + $1.duration) }) : 0
        return max(0, max(motion, max(effects, source)))
    }

    var end: CFTimeInterval {
        begin + duration
    }

    var terminal: ShellGlassShape {
        shape(at: carrier != nil && (bound != nil || !triggerPlans.isEmpty) ? end : .infinity)
    }

    mutating func finish(at time: CFTimeInterval) {
        begin = time
        base = ShellShapeBaseMotion(from: base.target, to: base.target, begin: time)
        plan = nil
        impulses = []
        edges = nil
        triggerPlans = []
        if let bound {
            let placement = bound.input.presentation.placement(at: .infinity)
            self.bound = ShellBoundTrack(
                input: ShellBoundInput(
                    layout: bound.input.layout,
                    canvas: bound.input.canvas,
                    presentation: .still(
                        translation: placement.translation,
                        scale: placement.scale,
                        clip: nil
                    ),
                    active: false,
                    time: time,
                    animates: bound.input.animates, binding: bound.input.binding
                ),
                source: bound.source, previous: nil, revision: bound.revision
            )
        }
    }

    func shape(at time: CFTimeInterval) -> ShellGlassShape {
        var raw = base.state(at: time).shape
        if let edges {
            let rect = edges.rect(at: time)
            let span = min(raw.rect.width, raw.rect.height)
            let radius = span > 0 ? raw.radius * min(rect.width, rect.height) / span : 0
            raw = raw.with(rect: rect, radius: radius)
        }
        if let contact = triggerPlans.last(where: { $0.begin <= time })?.contact {
            raw = contact.place(raw)
        }
        let state = progress(at: time)
        let morphed = morph.shape(raw, progress: state.progress, velocity: state.velocity)
        let shape = bound?.place(morphed, progress: state.progress, at: time) ?? morphed
        var width = 0.0, height = 0.0, x = 0.0, y = 0.0
        for impulse in impulses {
            let delta = impulse.state(at: time).displacement
            let dw = delta * impulse.width, dh = delta * impulse.height
            let pivot = impulse.pivot == .centre ? CGPoint(x: 0.5, y: 0.5) : morph.anchor
            width += dw
            height += dh
            x -= dw * pivot.x
            y -= dh * pivot.y
        }
        let rect = CGRect(
            x: shape.rect.minX + x, y: shape.rect.minY + y,
            width: max(0, shape.rect.width + width), height: max(0, shape.rect.height + height)
        )
        return shape.with(rect: rect, radius: min(shape.radius, min(rect.width, rect.height) / 2))
    }

    func progress(at time: CFTimeInterval) -> (progress: Double, velocity: Double) {
        let active = triggerPlans.isEmpty ? plan : triggerPlans.last { $0.begin <= time }
        return bound?.state(at: time) ?? active?.state(at: time)
            ?? (progress: morph.waits ? 0 : 1, velocity: 0)
    }

    var samples: [ShellGlassBody.TrackSample] {
        let duration = max(0, self.duration)
        var times = [0.0, duration]
        let rate = bound?.input.active == true ? 60.0 : ShellReveal.rate
        let count = Int(ceil(duration * rate))
        let events = triggerPlans.map(\.begin) + impulses.map(\.begin)
        let first = bound == nil && plan == nil && edges == nil && base.end <= begin
            ? events.min().map { max(0, Int(ceil(($0 - begin) * rate)) - 1) } ?? 0 : 0
        if count > first { times += (first ..< count).map { Double($0) / rate } }
        if let bound { times += bound.clampCrossings.map { $0 - begin } }
        if let plan { times.append(max(0, plan.begin - begin)) }
        times += impulses.map { max(0, $0.begin - begin) }
        times += triggerPlans.map { max(0, $0.begin - begin) }
        return Array(Set(times.filter { $0 >= 0 && $0 <= duration })).sorted().map {
            ShellGlassBody.TrackSample(time: $0, shape: $0 == duration ? terminal : shape(at: begin + $0))
        }
    }
}

final class ShellShapeTrackStore {
    var pendingBounds: [Int32: ShellBoundInput] = [:]
    var departures: [Int32: [ShellFollowExitBinding]] = [:]
    var entries: [Int32: ShellShapeTrackEntry] = [:]
    var retired: [ShellLayerIdentity: Int32] = [:]
    var updatedBodies: Set<Int32> = []
    var presets: [Int32: ShellAnimation] = [:]
    var generation: UInt64 = 0
    var nextRetired: Int32 = .max
    var contours: Set<Int32> = []
    var follows: [Int32: ShellShapeFollow] = [:]
    var retainedFollowers: [Int32: Set<Int32>] = [:]
    var retainedBounds: [Int32: Set<Int32>] = [:]

    static let identityMorph = ShellMorphRecipe("morph:0.5:0.5:0:0:0:0:0,1,1,1,1,1;1,1,1,1,1,1")
}

extension ShellGlassShape {
    func with(slot: Int32? = nil, rect: CGRect? = nil, radius: CGFloat? = nil) -> ShellGlassShape {
        ShellGlassShape(
            slot: slot ?? self.slot, kind: kind, rect: rect ?? self.rect, radius: radius ?? self.radius,
            thickness: thickness, rotation: rotation
        )
    }
}
