// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

enum ShellFollowRadius: Sendable {
    case scaled
    case fixed
}

struct ShellShapeFollow {
    enum Mode {
        case none
        case transform
        case composite
    }

    var radius: ShellFollowRadius?
    var binding: ShellShapeFollowBinding?
    var presentation = ShellManipulationPresentation.identity
    var departure: ShellShapeDeparture?
    var mode = Mode.none
    var dirty = true

    var begin: CFTimeInterval? {
        switch (presentation.begin, departure?.begin) {
        case let (first?, second?): min(first, second)
        case let (first, second): first ?? second
        }
    }

    var end: CFTimeInterval {
        max(presentation.end, departure?.end ?? -.infinity)
    }

    func shape(_ shape: ShellGlassShape, origin: CGPoint, at time: CFTimeInterval) -> ShellGlassShape {
        let radius = shape.radius
        let shape = departure?.shape(shape, at: time) ?? shape
        let (translation, scale) = presentation.placement(at: time)
        return ShellGlassShape(
            slot: shape.slot,
            kind: shape.kind,
            rect: CGRect(
                x: origin.x + translation.x + scale * (shape.rect.minX - origin.x),
                y: origin.y + translation.y + scale * (shape.rect.minY - origin.y),
                width: shape.rect.width * scale,
                height: shape.rect.height * scale
            ),
            radius: self.radius == .fixed ? radius : shape.radius * scale,
            thickness: shape.thickness * scale,
            rotation: shape.rotation
        )
    }
}

private struct ShellFollowedShape {
    let slot: Int32
    let raw: ShellGlassShape
    let entry: ShellShapeTrackEntry?
    let body: ShellGlassBody
}

extension ShellWrapperMotion.Channel {
    var end: CFTimeInterval {
        begin + duration
    }

    func value(at time: CFTimeInterval) -> Double {
        guard time < end else { return to }
        return to + ShellSpringDynamics.position(
            at: max(0, time - begin), displacement: from - to, initialVelocity: velocity, spring: spring
        )
    }
}

extension ShellManipulationPresentation {
    var isIdentity: Bool {
        guard case let .still(translation, scale, _) = self else { return false }
        return translation == .zero && scale == 1
    }

    var begin: CFTimeInterval? {
        guard case let .motion(motion) = self else { return nil }
        return motion.x.begin
    }

    var end: CFTimeInterval {
        guard case let .motion(motion) = self else { return -.infinity }
        return max(motion.x.end, motion.y.end, motion.scale.end)
    }

    func placement(at time: CFTimeInterval) -> (translation: CGPoint, scale: CGFloat) {
        switch self {
        case let .still(translation, scale, _): (translation, scale)
        case let .motion(motion):
            (CGPoint(x: motion.x.value(at: time), y: motion.y.value(at: time)), motion.scale.value(at: time))
        }
    }
}

extension ShellLayerScene {
    private static let followKeys = ["omni.follow.translation.x", "omni.follow.translation.y", "omni.follow.scale"]

    func bindShapeFollow(_ slot: Int32, _ radius: ShellFollowRadius?) {
        var follow = shapeTracks.follows[slot] ?? ShellShapeFollow()
        guard radius != nil || shapeTracks.follows[slot] != nil, follow.radius != radius else { return }
        follow.radius = radius
        if radius == nil { follow.presentation = .identity }
        follow.dirty = true
        shapeTracks.follows[slot] = follow
    }

    func followShape(_ slot: Int32, _ presentation: ShellManipulationPresentation) {
        guard shapeTracks.follows[slot]?.radius != nil else { return }
        shapeTracks.follows[slot]?.presentation = presentation
        shapeTracks.follows[slot]?.departure = nil
        shapeTracks.follows[slot]?.dirty = true
    }

    func flushShapeFollows() {
        guard !shapeTracks.follows.isEmpty else { return }
        let now = CACurrentMediaTime()
        for slot in Array(shapeTracks.follows.keys) {
            guard var follow = shapeTracks.follows[slot] else { continue }
            let entry = shapeTracks.entries[slot]
            guard let raw = glassShapes[slot], let owner = entry?.body ?? parents[slot], let body = glassBodies[owner]
            else {
                forgetShapeBindings(slot)
                continue
            }
            let shape = ShellFollowedShape(slot: slot, raw: raw, entry: entry, body: body)
            let refreshed = shapeTracks.updatedBodies.contains(owner)
            let mode = Self.followMode(follow, on: shape, at: now)
            let changed = follow.dirty || mode != follow.mode
            if changed { retireFollow(follow.mode, on: shape) }
            switch mode {
            case .none:
                break
            case .transform:
                if changed || refreshed { holdFollow(follow, on: shape, replacing: changed) }
            case .composite:
                if changed { composeFollow(follow, on: shape, at: now) }
            }
            follow.mode = mode
            follow.dirty = false
            shapeTracks.follows[slot] = follow.radius == nil ? nil : follow
        }
    }

    struct ShapeTrackPlan {
        let begin: CFTimeInterval
        let samples: [ShellGlassBody.TrackSample]
        let duration: CFTimeInterval
    }

    func trackPlan(
        _ entry: ShellShapeTrackEntry, slot: Int32, includingTransform: Bool = false
    ) -> ShapeTrackPlan {
        let follow = shapeTracks.follows[slot]
        guard let follow, follow.mode == .composite || includingTransform && follow.mode == .transform else {
            return ShapeTrackPlan(begin: entry.begin, samples: entry.samples, duration: max(0, entry.duration))
        }
        var entry = entry
        if follow.mode == .transform { entry.begin = Self.followStart(follow, at: CACurrentMediaTime()) }
        let base = max(0, entry.duration)
        let samples = entry.samples
        let origin = entry.base.target.rect.origin
        let duration = entry.carrier == nil ? max(base, follow.end - entry.begin) : base
        var times = Set(samples.map(\.time).filter { $0 < base })
        for index in 0 ..< Int((duration * ShellReveal.rate).rounded(.up)) {
            times.insert(Double(index) / ShellReveal.rate)
        }
        var composite = times.filter { $0 < duration }.sorted().map { time in
            ShellGlassBody.TrackSample(
                time: time,
                shape: follow.shape(entry.shape(at: entry.begin + time), origin: origin, at: entry.begin + time)
            )
        }
        let terminalTime = entry.carrier == nil ? CFTimeInterval.infinity : entry.end
        composite.append(.init(time: duration, shape: follow.shape(entry.terminal, origin: origin, at: terminalTime)))
        return ShapeTrackPlan(begin: entry.begin, samples: composite, duration: duration)
    }

    func trackTerminal(_ entry: ShellShapeTrackEntry, slot: Int32) -> ShellGlassShape {
        guard let follow = shapeTracks.follows[slot], follow.mode == .composite else { return entry.terminal }
        return follow.shape(
            entry.terminal, origin: entry.base.target.rect.origin,
            at: entry.carrier == nil ? .infinity : entry.end
        )
    }

    func replanShapeFollows() {
        let now = CACurrentMediaTime()
        for (slot, follow) in shapeTracks.follows where follow.mode == .composite {
            guard var entry = shapeTracks.entries[slot], entry.carrier == nil, let body = glassBodies[entry.body]
            else { continue }
            entry.begin = Self.followStart(follow, at: now)
            let plan = trackPlan(entry, slot: slot)
            let built = body.trackAnimations(plan.samples, begin: plan.begin, duration: plan.duration)
            for item in built.items {
                item.layer.add(item.animation, forKey: item.key)
            }
            entry.animations = built.items
            entry.union = built.union
            shapeTracks.entries[slot] = entry
        }
    }

    private static func followMode(
        _ follow: ShellShapeFollow,
        on shape: ShellFollowedShape,
        at now: CFTimeInterval
    ) -> ShellShapeFollow.Mode {
        guard follow.radius != nil else { return .none }
        if follow.departure != nil { return .composite }
        guard !follow.presentation.isIdentity else { return .none }
        if let entry = shape.entry, entry.end > now { return .composite }
        let raw = shape.raw
        return raw.kind != 0 || raw.rotation != 0 || follow.radius == .fixed ? .composite : .transform
    }

    private func retireFollow(_ mode: ShellShapeFollow.Mode, on shape: ShellFollowedShape) {
        switch mode {
        case .none:
            break
        case .transform:
            for layer in shape.body.lockstepLayers(shape.slot) {
                for key in Self.followKeys {
                    layer.removeAnimation(forKey: key)
                }
            }
        case .composite:
            shapeTracks.entries[shape.slot]?.dirty = true
        }
    }

    private func holdFollow(_ follow: ShellShapeFollow, on shape: ShellFollowedShape, replacing: Bool) {
        var presentation = follow.presentation
        if let entry = shape.entry {
            if replacing {
                shape.body.removeTrack(shape.slot)
                shape.body.setTrackGeometry(entry.terminal)
            }
            let origin = entry.terminal.rect.origin
            presentation = presentation.following(
                CGPoint(x: shape.raw.rect.minX - origin.x, y: shape.raw.rect.minY - origin.y)
            )
        }
        let animations = Self.heldAnimations(presentation, in: shape.body)
        for layer in shape.body.lockstepLayers(shape.slot)
            where replacing || layer.animation(forKey: Self.followKeys[0]) == nil
        {
            for (key, animation) in zip(Self.followKeys, animations) {
                layer.add(animation, forKey: key)
            }
        }
    }

    private static func followStart(_ follow: ShellShapeFollow, at now: CFTimeInterval) -> CFTimeInterval {
        follow.end > now ? follow.begin ?? now : now
    }

    private func composeFollow(_ follow: ShellShapeFollow, on shape: ShellFollowedShape, at now: CFTimeInterval) {
        guard var entry = shape.entry else { return }
        if entry.end <= now { entry.begin = Self.followStart(follow, at: now) }
        entry.dirty = true
        shapeTracks.entries[shape.slot] = entry
    }

    private static func heldAnimations(
        _ presentation: ShellManipulationPresentation,
        in body: ShellGlassBody
    ) -> [CAAnimation] {
        let animations: [CAAnimation] = switch presentation {
        case let .still(translation, scale, _):
            zip(manipulationKeys, [translation.x, translation.y, scale]).map { hold($0, at: $1) }
        case let .motion(motion):
            zip(manipulationKeys, [motion.x, motion.y, motion.scale]).map { path, channel in
                channel.duration > 0
                    ? manipulationSpring(
                        channel,
                        keyPath: path,
                        begin: body.layer.convertTime(channel.begin, from: nil)
                    )
                    : hold(path, at: channel.to)
            }
        }
        for animation in animations {
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
        }
        return animations
    }

    private static func hold(_ keyPath: String, at value: CGFloat) -> CABasicAnimation {
        let hold = CABasicAnimation(keyPath: keyPath)
        hold.fromValue = value
        hold.toValue = value
        return hold
    }
}
