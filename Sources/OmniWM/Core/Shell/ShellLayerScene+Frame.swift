// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import QuartzCore

extension ShellLayerScene {
    func applyFrame(_ slot: Int32, _ rect: CGRect, preset: ShellAnimation?, animated: Bool) {
        guard let layer = layers[slot] else { return }
        exitAnimations[slot] = preset
        let entering = framed.insert(slot).inserted
        let animation = animated ? preset : nil
        let bounds = CGRect(
            origin: scrollOrigins[slot] ?? .zero,
            size: quarters.contains(slot) ? CGSize(width: rect.height, height: rect.width) : rect.size
        )
        if !entering { animateFrame(of: layer, to: rect, bounds: bounds, animation: animation) }
        layer.position = rect.origin
        layer.bounds = bounds
        updateGestureCenter(slot)
        applyLoop(slot, loops[slot]?.loop, to: layer)
        layoutProgress(slot, animation: entering ? nil : animation)
        layoutMaterial(slot, in: layer)
        applyScale(slot, to: layer)
        shaders?.resize(slot)
        if paths[slot] != nil { layoutPath(slot, animation: entering ? nil : animation) }
        if let mask = masks[slot] { Self.align(mask.layer, with: layer) }
        if enters[slot] != nil { applyEnter(slot, to: layer) }
        if entering { applyAppearance(slot, to: layer, preset: preset, animated: animated) }
    }

    private func animateFrame(of layer: CALayer, to rect: CGRect, bounds: CGRect, animation: ShellAnimation?) {
        guard let animation else { return }
        if animation.trails, let trail = animation.trail(
            from: (layer.presentation() ?? layer).frame, to: rect, origin: bounds.origin
        ) {
            removeScalarFrameAnimations(from: layer)
            layer.add(trail.position, forKey: "position")
            layer.add(trail.bounds, forKey: "bounds")
            return
        }
        let from = layer.presentation() ?? layer
        if animation.motion.isSpring {
            animateSpringFrame(animation, of: layer, from: from, rect: rect, bounds: bounds)
        } else {
            removeScalarFrameAnimations(from: layer)
            add(
                animation,
                to: layer,
                "position",
                from: NSValue(point: from.position),
                to: NSValue(point: rect.origin),
                changed: from.position != rect.origin
            )
            add(
                animation,
                to: layer,
                "bounds",
                from: NSValue(rect: from.bounds),
                to: NSValue(rect: bounds),
                changed: from.bounds != bounds
            )
        }
    }

    private func animateSpringFrame(
        _ animation: ShellAnimation, of layer: CALayer, from: CALayer, rect: CGRect, bounds: CGRect
    ) {
        layer.removeAnimation(forKey: "position")
        layer.removeAnimation(forKey: "bounds")
        add(
            animation,
            to: layer,
            "position.x",
            from: from.position.x,
            to: rect.minX,
            changed: from.position.x != rect.minX
        )
        add(
            animation,
            to: layer,
            "position.y",
            from: from.position.y,
            to: rect.minY,
            changed: from.position.y != rect.minY
        )
        add(
            animation,
            to: layer,
            "bounds.size.width",
            from: from.bounds.width,
            to: bounds.width,
            changed: from.bounds.width != bounds.width
        )
        add(
            animation,
            to: layer,
            "bounds.size.height",
            from: from.bounds.height,
            to: bounds.height,
            changed: from.bounds.height != bounds.height
        )
    }

    private func removeScalarFrameAnimations(from layer: CALayer) {
        layer.removeAnimation(forKey: "position.x")
        layer.removeAnimation(forKey: "position.y")
        layer.removeAnimation(forKey: "bounds.size.width")
        layer.removeAnimation(forKey: "bounds.size.height")
    }

    func add(
        _ animation: ShellAnimation,
        to layer: CALayer,
        _ keyPath: String,
        from: Any?,
        to: Any?,
        changed: Bool = true,
        velocity: Double? = nil
    ) {
        guard changed else { return }
        let target = to
        if let keyframes = animation.keyframes(keyPath, from: from, to: target) {
            layer.add(keyframes, forKey: keyPath)
            return
        }
        let basic = animation.make(keyPath)
        basic.fromValue = from
        basic.toValue = target
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        if let spring = basic as? CASpringAnimation,
           let from = from as? NSNumber, let to = target as? NSNumber
        {
            let remaining = to.doubleValue - from.doubleValue
            let physical = velocity ?? Self.springVelocity(layer.animation(forKey: keyPath), at: now)
            if remaining != 0, physical.isFinite {
                spring.initialVelocity = min(max(physical / remaining, -20), 20)
                spring.duration = spring.settlingDuration
            }
        }
        basic.beginTime = now
        layer.add(basic, forKey: keyPath)
    }

    static func springVelocity(_ animation: CAAnimation?, at time: CFTimeInterval) -> Double {
        guard let spring = animation as? CASpringAnimation,
              let from = spring.fromValue as? NSNumber, let to = spring.toValue as? NSNumber else { return 0 }
        let elapsed = (time - spring.beginTime) * Double(spring.speed) + spring.timeOffset
        guard elapsed >= 0, elapsed < spring.duration else { return 0 }
        let distance = to.doubleValue - from.doubleValue
        return ShellSpringDynamics.velocity(
            at: elapsed, displacement: -distance, initialVelocity: spring.initialVelocity * distance,
            spring: .init(mass: spring.mass, stiffness: spring.stiffness, damping: spring.damping)
        ) * Double(spring.speed)
    }
}
