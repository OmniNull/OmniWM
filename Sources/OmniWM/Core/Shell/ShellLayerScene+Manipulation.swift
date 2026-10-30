// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

final class ShellManipulationCompletion: NSObject, CAAnimationDelegate, Sendable {
    let completion: @Sendable (Bool) -> Void

    init(_ completion: @escaping @Sendable (Bool) -> Void) {
        self.completion = completion
    }

    func animationDidStop(_: CAAnimation, finished: Bool) {
        completion(finished)
    }
}

extension ShellLayerScene {
    static let manipulationKeys = ["transform.translation.x", "transform.translation.y", "transform.scale"]

    func applyManipulation(
        _ slot: Int32,
        token: UInt64,
        presentation: ShellManipulationPresentation,
        active: Bool
    ) {
        if glassShapes[slot] != nil {
            followShape(slot, presentation)
            return
        }
        var ending = false
        if case .still = presentation { ending = !active }
        guard var state = ending ? gestureLayers[slot] : gestureWrapper(slot),
              !ending || state.token == token, let content = layers[slot] else { return }
        let layer = state.layer
        if state.token != token {
            state.token = token
            clearGestureAnimations(layer)
        }
        state.active = active
        var clip: ShellManipulationClip?
        switch presentation {
        case let .still(translation, factor, region):
            clip = region
            state.moving = false
            if ending { state.token = 0 }
            removeManipulationAnimations(layer)
            layer.transform = Self.manipulationTransform(translation.x, translation.y, factor)
        case let .motion(motion):
            state.generation &+= 1
            let completion = active ? nil : manipulationCompletion(slot, token: token, generation: state.generation)
            let animated = animateManipulation(motion, on: layer, completion: completion)
            state.moving = animated || completion != nil
            if !animated { completion?.completion(true) }
        }
        layer.opacity = 1
        layer.position = content.position
        layer.bounds = CGRect(origin: content.position, size: clip?.size ?? content.bounds.size)
        layer.masksToBounds = clip != nil
        layer.borderWidth = clip?.outline == nil ? 0 : 1 / scale
        layer.borderColor = clip?.outline
        layer.cornerRadius = content.cornerRadius
        layer.zPosition = state.zPosition
        gestureLayers[slot] = state
        updateGestureCenter(slot)
    }

    func raise(_ slot: Int32, _ raised: Bool) {
        guard var state = raised ? gestureWrapper(slot) : gestureLayers[slot] else { return }
        state.raised = raised
        gestureLayers[slot] = state
        state.layer.zPosition = state.zPosition
        if !raised { updateGestureCenter(slot) }
    }

    private func animateManipulation(
        _ motion: ShellWrapperMotion,
        on layer: CALayer,
        completion: ShellManipulationCompletion?
    ) -> Bool {
        let channels: InlineArray<3, ShellWrapperMotion.Channel> = [motion.x, motion.y, motion.scale]
        var last = 0
        for index in channels.indices
            where channels[index].begin + channels[index].duration > channels[last].begin + channels[last].duration
        {
            last = index
        }
        layer.transform = Self.manipulationTransform(motion.x.to, motion.y.to, motion.scale.to)
        guard channels[last].duration > 0 else {
            removeManipulationAnimations(layer)
            return false
        }
        for index in channels.indices {
            let channel = channels[index]
            let spring = Self.manipulationSpring(
                channel, keyPath: Self.manipulationKeys[index], begin: layer.convertTime(channel.begin, from: nil)
            )
            if index == last { spring.delegate = completion }
            layer.add(spring, forKey: Self.manipulationKeys[index])
        }
        return true
    }

    static func manipulationSpring(
        _ channel: ShellWrapperMotion.Channel,
        keyPath: String,
        begin: CFTimeInterval
    ) -> CASpringAnimation {
        var from = channel.from
        if abs(channel.to - from) < 1e-3, channel.velocity != 0 {
            from = channel.to - copysign(1e-3, channel.velocity)
        }
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = channel.spring.mass
        spring.stiffness = channel.spring.stiffness
        spring.damping = channel.spring.damping
        spring.fromValue = from
        spring.toValue = channel.to
        spring.initialVelocity = channel.velocity == 0 ? 0 : channel.velocity / (channel.to - from)
        spring.duration = channel.duration
        spring.beginTime = begin
        return spring
    }

    private func manipulationCompletion(
        _ slot: Int32,
        token: UInt64,
        generation: UInt64
    ) -> ShellManipulationCompletion {
        ShellManipulationCompletion { [weak self] finished in
            Self.engineQueue.async { [weak self] in
                self?.settleManipulation(slot, token: token, generation: generation, finished: finished)
            }
        }
    }

    private func settleManipulation(_ slot: Int32, token: UInt64, generation: UInt64, finished: Bool) {
        guard finished, var state = gestureLayers[slot], state.token == token, state.generation == generation,
              state.moving else { return }
        state.moving = false
        gestureLayers[slot] = state
        guard let settled = onManipulationSettled else { return }
        DispatchQueue.main.async { settled(slot, token, generation) }
    }

    private func removeManipulationAnimations(_ layer: CALayer) {
        for key in Self.manipulationKeys {
            layer.removeAnimation(forKey: key)
        }
    }

    private static func manipulationTransform(_ x: CGFloat, _ y: CGFloat, _ scale: CGFloat) -> CATransform3D {
        CATransform3DScale(CATransform3DMakeTranslation(x, y, 0), scale, scale, 1)
    }
}
