// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMShellCore
import QuartzCore

struct ShellLayerIdentity: Hashable, Sendable {
    let parent: ElementHandle
    let key: UInt64
    let kind: UInt8

    init(parent: ElementHandle, key: UInt64, kind: ElementKind) {
        self.parent = parent
        self.key = key
        self.kind = kind.rawValue
    }
}

struct ShellPresence: Sendable {
    let opacity: Float
    let scale: CGFloat
    let offset: CGPoint
    let animation: ShellAnimation?
    let anchor: CGPoint
    let delay: CFTimeInterval

    init(
        opacity: Float, scale: CGFloat, offset: CGPoint, animation: ShellAnimation?,
        anchor: CGPoint = CGPoint(x: 0.5, y: 0.5), delay: CFTimeInterval = 0
    ) {
        self.opacity = opacity
        self.scale = scale
        self.offset = offset
        self.animation = animation
        self.anchor = anchor
        self.delay = delay
    }

    func transform(from base: CATransform3D, size: CGSize) -> CATransform3D {
        Self.transform(from: base, size: size, anchor: anchor, scale: scale, offset: offset)
    }

    static func transform(
        from base: CATransform3D, size: CGSize, anchor: CGPoint, scale: CGFloat, offset: CGPoint = .zero
    ) -> CATransform3D {
        let pivot = CGPoint(x: size.width * anchor.x, y: size.height * anchor.y)
        var delta = CATransform3DMakeTranslation(pivot.x + offset.x, pivot.y + offset.y, 0)
        delta = CATransform3DScale(delta, scale, scale, 1)
        delta = CATransform3DTranslate(delta, -pivot.x, -pivot.y, 0)
        return CATransform3DConcat(base, delta)
    }

    func group(
        fromOpacity: Float,
        toOpacity: Float,
        fromTransform: CATransform3D,
        toTransform: CATransform3D,
        at time: CFTimeInterval = CACurrentMediaTime()
    ) -> CAAnimationGroup? {
        guard let animation else { return nil }
        var animations: [CAAnimation] = []
        if fromOpacity != toOpacity {
            animations.append(Self.property(animation, "opacity", from: fromOpacity, to: toOpacity))
        }
        if !CATransform3DEqualToTransform(fromTransform, toTransform) {
            animations.append(Self.property(
                animation, "transform",
                from: NSValue(caTransform3D: fromTransform), to: NSValue(caTransform3D: toTransform)
            ))
        }
        guard !animations.isEmpty else { return nil }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = animations.reduce(0) { max($0, $1.duration) }
        group.beginTime = time + delay / animation.speed
        group.fillMode = .backwards
        return group
    }

    private static func property(_ animation: ShellAnimation, _ path: String, from: Any, to: Any) -> CAAnimation {
        if let keyframes = animation.keyframes(path, from: from, to: to) { return keyframes }
        let basic = animation.make(path)
        basic.fromValue = from
        basic.toValue = to
        return basic
    }

    static func fade(_ animation: ShellAnimation) -> ShellPresence {
        ShellPresence(
            opacity: 0, scale: 1, offset: .zero,
            animation: ShellAnimation(
                motion: .ease(seconds: 0.18), speed: animation.speed, curve: ShellCurve(wire: 1, custom: nil)
            )
        )
    }
}

final class ShellPresenceCompletion: NSObject, CAAnimationDelegate, Sendable {
    let completion: @Sendable () -> Void

    init(_ completion: @escaping @Sendable () -> Void) {
        self.completion = completion
    }

    func animationDidStop(_: CAAnimation, finished _: Bool) {
        completion()
    }
}

final class ShellPresenceState {
    struct Departure {
        let slot: Int32
        let layer: CALayer
        let key: String
        let completion: ShellPresenceCompletion
    }

    struct Plan {
        let slot: Int32
        let layer: CALayer
        let animation: CAAnimationGroup
        let opacity: Float
        let transform: CATransform3D
        let fromTransform: CATransform3D
        let departure: ShellPresence
    }

    struct Retained {
        let subtree: CALayer
        let identity: ShellLayerIdentity?
        var animations: [UInt64: Departure] = [:]
        var pending: Set<UInt64> = []
        var nextCompletion: UInt64 = 0
    }

    var appearances: [Int32: ShellPresence] = [:]
    var departures: [Int32: ShellPresence] = [:]
    var identities: [Int32: ShellLayerIdentity] = [:]
    var reveals: [Int32: ShellRevealRecipe] = [:]
    var revealPlans: [Int32: (plan: ShellReveal, token: UInt64)] = [:]
    var morphs: [Int32: ShellMorphRecipe] = [:]
    var dirtyReveals: Set<Int32> = []
    var onRevealSettled: (@MainActor @Sendable (Int32, UInt64) -> Void)?
    var retained: [UInt64: Retained] = [:]
    var retainedByIdentity: [ShellLayerIdentity: UInt64] = [:]
    var nextToken: UInt64 = 0
}

extension ShellLayerScene {
    static let appearanceKey = "omni.presence.appear"
    static let departureKey = "omni.presence.exit"

    func insertPresence(_ slot: Int32, identity: ShellLayerIdentity?) {
        if let identity, let previous = presence.retainedByIdentity[identity] {
            finishPresenceExit(previous)
        }
        presence.identities[slot] = identity
    }

    func setPresence(
        _ slot: Int32,
        appear: ShellPresence?,
        exit: ShellPresence?,
        reveal: ShellRevealRecipe? = nil,
        morph: ShellMorphRecipe? = nil
    ) {
        presence.appearances[slot] = appear
        presence.departures[slot] = exit
        presence.reveals[slot] = reveal
        presence.morphs[slot] = morph
    }

    func presentedContent(_ slot: Int32) -> CALayer? {
        effects[slot].flatMap { $0.output.superlayer == nil ? nil : $0.output } ?? layers[slot]
    }

    func applyAppearance(_ slot: Int32, to layer: CALayer, preset: ShellAnimation?, animated: Bool) {
        guard animated,
              let appearance = presence.appearances[slot] ?? preset.map({
                  ShellPresence(opacity: 0, scale: 1, offset: .zero, animation: $0)
              }),
              let group = appearance.group(
                  fromOpacity: layer.opacity * appearance.opacity,
                  toOpacity: layer.opacity,
                  fromTransform: appearance.transform(from: layer.transform, size: layer.bounds.size),
                  toTransform: layer.transform,
                  at: layer.convertTime(now(), from: nil)
              )
        else { return }
        layer.add(group, forKey: Self.appearanceKey)
    }

    func retirePresence(
        _ slot: Int32, subtree: CALayer, animated: Bool, children: [Int32: Set<Int32>] = [:]
    ) {
        guard animated else {
            subtree.removeFromSuperlayer()
            return
        }
        let now = self.now()
        let descendants = presence.reveals[slot] == nil ? [] : presenceDescendants(slot, children: children)
        let plans = ([slot] + descendants).compactMap { presencePlan($0, root: slot, at: now) }
        let closing = presence.revealPlans[slot].flatMap { $0.plan.target == 0 ? $0.plan : nil }
        let reveal = closing.map { revealAnimations(slot, plan: $0, children: children, closing: true) } ?? []
        guard !plans.isEmpty || !reveal.isEmpty else {
            subtree.removeFromSuperlayer()
            return
        }
        presence.nextToken += 1
        let token = presence.nextToken
        let identity = presence.identities[slot]
        presence.retained[token] = ShellPresenceState.Retained(subtree: subtree, identity: identity)
        if let identity { presence.retainedByIdentity[identity] = token }
        for plan in plans {
            departShapeFollowers(with: plan)
            plan.animation.delegate = addPresenceCompletion(
                token,
                slot: plan.slot,
                layer: plan.layer,
                key: Self.departureKey
            )
            plan.layer.removeAnimation(forKey: Self.appearanceKey)
            plan.layer.opacity = plan.opacity
            plan.layer.transform = plan.transform
            plan.layer.add(plan.animation, forKey: Self.departureKey)
        }
        if let first = reveal.first {
            first.animation.delegate = addPresenceCompletion(token, slot: slot, layer: first.layer, key: first.key)
        }
        for item in reveal {
            item.layer.add(item.animation, forKey: item.key)
        }
    }

    private func presenceDescendants(_ slot: Int32, children: [Int32: Set<Int32>]) -> [Int32] {
        var result: [Int32] = []
        func collect(_ parent: Int32) {
            for child in children[parent] ?? [] {
                if presence.departures[child] != nil {
                    result.append(child)
                } else {
                    collect(child)
                }
            }
        }
        collect(slot)
        return result
    }

    private func presencePlan(_ slot: Int32, root: Int32, at time: CFTimeInterval) -> ShellPresenceState.Plan? {
        guard let layer = presentedContent(slot),
              let departure = presence.departures[slot]
              ?? (slot == root ? exitAnimations[slot].map(ShellPresence.fade) : nil)
        else { return nil }
        let shown = layer.presentation() ?? layer
        let opacity = layer.opacity * departure.opacity
        let transform = departure.transform(from: layer.transform, size: layer.bounds.size)
        guard let group = departure.group(
            fromOpacity: shown.opacity, toOpacity: opacity, fromTransform: shown.transform, toTransform: transform,
            at: layer.convertTime(time, from: nil)
        ) else { return nil }
        return ShellPresenceState.Plan(
            slot: slot,
            layer: layer,
            animation: group,
            opacity: opacity,
            transform: transform,
            fromTransform: shown.transform,
            departure: departure
        )
    }

    func addPresenceCompletion(
        _ token: UInt64, slot: Int32, layer: CALayer, key: String
    ) -> ShellPresenceCompletion? {
        guard let identifier = presence.retained[token]?.nextCompletion else { return nil }
        let completion = ShellPresenceCompletion { [self] in
            Self.engineQueue.async { [self] in completePresenceAnimation(token, identifier: identifier) }
        }
        presence.retained[token]?.nextCompletion += 1
        presence.retained[token]?.pending.insert(identifier)
        presence.retained[token]?.animations[identifier] = ShellPresenceState.Departure(
            slot: slot, layer: layer, key: key, completion: completion
        )
        return completion
    }

    func completePresenceAnimation(_ token: UInt64, identifier: UInt64) {
        guard presence.retained[token]?.pending.remove(identifier) != nil else { return }
        if presence.retained[token]?.pending.isEmpty == true { finishPresenceExit(token) }
    }

    func finishPresenceExit(_ token: UInt64) {
        guard let retained = presence.retained.removeValue(forKey: token) else { return }
        if let identity = retained.identity, presence.retainedByIdentity[identity] == token {
            presence.retainedByIdentity.removeValue(forKey: identity)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for departure in retained.animations.values { departure.layer.removeAnimation(forKey: departure.key) }
        retained.subtree.removeFromSuperlayer()
        CATransaction.commit()
    }

    func finishAllPresenceExits() {
        for token in Array(presence.retained.keys) {
            finishPresenceExit(token)
        }
    }

    func forgetPresence(_ slot: Int32) {
        shapeTracks.departures.removeValue(forKey: slot)
        presence.appearances.removeValue(forKey: slot)
        presence.departures.removeValue(forKey: slot)
        presence.identities.removeValue(forKey: slot)
        presence.reveals.removeValue(forKey: slot)
        presence.revealPlans.removeValue(forKey: slot)
        presence.morphs.removeValue(forKey: slot)
        presence.dirtyReveals.remove(slot)
    }
}
