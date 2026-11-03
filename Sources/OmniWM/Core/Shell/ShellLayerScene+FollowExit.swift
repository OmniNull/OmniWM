// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMShellCore
import QuartzCore

struct ShellFollowExitBinding: Sendable {
    let shape: ElementHandle
    let identity: ShellLayerIdentity?
    let offset: CGPoint

    var slot: Int32 {
        shape.slot
    }
}

struct ShellShapeDeparture {
    let origin: CGPoint
    let from: SIMD3<Double>
    let to: SIMD3<Double>
    let spring: ShellSpringDynamics.Parameters?
    let curve: ShellCurve?
    let begin: CFTimeInterval
    let duration: CFTimeInterval

    var end: CFTimeInterval {
        begin + duration
    }

    func shape(_ shape: ShellGlassShape, at time: CFTimeInterval) -> ShellGlassShape {
        let progress: Double
        if time >= end { progress = 1 }
        else if time <= begin { progress = 0 }
        else if let spring {
            progress = 1 + ShellSpringDynamics.position(
                at: time - begin, displacement: -1, initialVelocity: 0, spring: spring
            )
        } else {
            progress = Double(curve?.value(
                at: (time - begin) / duration
            ) ?? 1)
        }
        let value = from + (to - from) * progress
        let scale = max(0, value[2])
        return ShellGlassShape(
            slot: shape.slot, kind: shape.kind,
            rect: CGRect(
                x: origin.x + value[0] + (shape.rect.minX - origin.x) * scale,
                y: origin.y + value[1] + (shape.rect.minY - origin.y) * scale,
                width: shape.rect.width * scale, height: shape.rect.height * scale
            ),
            radius: shape.radius * scale, thickness: shape.thickness * scale, rotation: shape.rotation
        )
    }
}

extension ShellLayerScene {
    func departShapeFollowers(with plan: ShellPresenceState.Plan) {
        guard let animation = plan.departure.animation else { return }
        var followers: [Int32: CGPoint] = [:]
        for binding in shapeTracks.departures.removeValue(forKey: plan.slot) ?? [] {
            let slot = binding.identity.flatMap { shapeTracks.retired[$0] } ?? binding.slot
            followers[slot] = binding.offset
        }
        for slot in shapeTracks.retainedFollowers[plan.slot] ?? [] {
            followers[slot] = shapeTracks.follows[slot]?.binding?.offset
        }
        for (slot, offset) in followers {
            let entry = shapeTracks.entries[slot]
            guard let raw = glassShapes[slot], shapeTracks.follows[slot]?.radius != nil,
                  let owner = entry?.body ?? parents[slot], glassBodies[owner] != nil else { continue }
            let reference = presence.revealPlans[plan.slot]?.plan.commit
                ?? presence.revealPlans[slot]?.plan.commit ?? entry?.plan?.commit
                ?? entry?.begin ?? now()
            let begin = reference + plan.animation.beginTime - plan.layer.convertTime(reference, from: nil)
            let scale = shapeTracks.follows[slot]?.binding?.layoutScale ?? 1
            shapeTracks.follows[slot]?.departure = ShellShapeDeparture(
                origin: CGPoint(x: raw.rect.minX + offset.x, y: raw.rect.minY + offset.y),
                from: SIMD3(plan.fromTransform.m41 / scale, plan.fromTransform.m42 / scale, plan.fromTransform.m11),
                to: SIMD3(plan.transform.m41 / scale, plan.transform.m42 / scale, plan.transform.m11),
                spring: ShellSpringDynamics.Parameters(animation),
                curve: animation.curve ?? ShellCurve(wire: 4, custom: nil),
                begin: begin, duration: plan.animation.duration
            )
            shapeTracks.follows[slot]?.dirty = true
        }
    }
}
