// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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

    func transform(from base: CATransform3D, size: CGSize) -> CATransform3D {
        var delta = CATransform3DMakeTranslation(size.width / 2 + offset.x, size.height / 2 + offset.y, 0)
        delta = CATransform3DScale(delta, scale, scale, 1)
        delta = CATransform3DTranslate(delta, -size.width / 2, -size.height / 2, 0)
        return CATransform3DConcat(base, delta)
    }

    func group(
        fromOpacity: Float,
        toOpacity: Float,
        fromTransform: CATransform3D,
        toTransform: CATransform3D
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
    struct Retained {
        let subtree: CALayer
        let animatedLayer: CALayer
        let identity: ShellLayerIdentity?
        let completion: ShellPresenceCompletion
    }

    var appearances: [Int32: ShellPresence] = [:]
    var departures: [Int32: ShellPresence] = [:]
    var identities: [Int32: ShellLayerIdentity] = [:]
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

    func setPresence(_ slot: Int32, appear: ShellPresence?, exit: ShellPresence?) {
        presence.appearances[slot] = appear
        presence.departures[slot] = exit
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
                  toTransform: layer.transform
              )
        else { return }
        layer.add(group, forKey: Self.appearanceKey)
    }

    func retirePresence(_ slot: Int32, subtree: CALayer, animated: Bool) {
        guard let layer = layers[slot], animated,
              let departure = presence.departures[slot] ?? exitAnimations[slot].map(ShellPresence.fade)
        else {
            subtree.removeFromSuperlayer()
            return
        }
        let shown = layer.presentation() ?? layer
        let targetOpacity = layer.opacity * departure.opacity
        let targetTransform = departure.transform(from: layer.transform, size: layer.bounds.size)
        guard let group = departure.group(
            fromOpacity: shown.opacity,
            toOpacity: targetOpacity,
            fromTransform: shown.transform,
            toTransform: targetTransform
        ) else {
            subtree.removeFromSuperlayer()
            return
        }
        presence.nextToken += 1
        let token = presence.nextToken
        let identity = presence.identities[slot]
        let completion = ShellPresenceCompletion { [self] in
            Self.engineQueue.async { [self] in finishPresenceExit(token) }
        }
        presence.retained[token] = ShellPresenceState.Retained(
            subtree: subtree, animatedLayer: layer, identity: identity, completion: completion
        )
        if let identity { presence.retainedByIdentity[identity] = token }
        group.delegate = completion
        layer.removeAnimation(forKey: Self.appearanceKey)
        layer.opacity = targetOpacity
        layer.transform = targetTransform
        layer.add(group, forKey: Self.departureKey)
    }

    func finishPresenceExit(_ token: UInt64) {
        guard let retained = presence.retained.removeValue(forKey: token) else { return }
        if let identity = retained.identity, presence.retainedByIdentity[identity] == token {
            presence.retainedByIdentity.removeValue(forKey: identity)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        retained.animatedLayer.removeAnimation(forKey: Self.departureKey)
        retained.subtree.removeFromSuperlayer()
        CATransaction.commit()
    }

    func finishAllPresenceExits() {
        for token in Array(presence.retained.keys) {
            finishPresenceExit(token)
        }
    }

    func forgetPresence(_ slot: Int32) {
        presence.appearances.removeValue(forKey: slot)
        presence.departures.removeValue(forKey: slot)
        presence.identities.removeValue(forKey: slot)
    }
}
